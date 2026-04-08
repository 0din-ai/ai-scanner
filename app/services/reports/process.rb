module Reports
  class Process
    ATTEMPT_KEYS = %w[uuid prompt outputs notes messages].freeze
    EVAL_KEYS = %w[detector passed total].freeze

    attr_reader :report, :id, :report_data, :detector_stats, :raw_data

    def initialize(id)
      @id = id
      @report_data = {}
      @detector_stats = {}
    end

    def call
      @raw_data = RawReportData.find_by(report_id: id)

      unless @raw_data&.jsonl_data.present?
        # Raise error to trigger Solid Queue retry - data may be pending commit
        raise StandardError, "Report #{id}: raw_report_data not found"
      end

      process_from_database
      Cleanup.new(report).call
      send_to_output_server
    end

    private

    def report
      @report ||= Report.find(id)
    end

    def process_from_database
      @raw_data.mark_processing!
      process_jsonl_data(@raw_data.jsonl_data)

      report.logs = @raw_data.logs_data if @raw_data.logs_data.present?
      report.save
      save_detector_results
      update_target_token_rate

      @raw_data.destroy!
      Rails.logger.info("Report #{id}: Processed from database, raw_report_data deleted")
    end

    def process_jsonl_data(jsonl_string)
      report.update(status: :processing)

      processed = false
      line_number = 0
      valid_lines = 0
      attempts_processed = false
      evals_processed = false

      jsonl_string.each_line do |line|
        line_number += 1
        next if line.strip.empty? # Skip empty lines

        begin
          data = JSON.parse(line)

          # Validate that we have an entry_type
          unless data.is_a?(Hash) && data["entry_type"]
            Rails.logger.warn "Report #{report.id}: Line #{line_number} missing entry_type, skipping"
            next
          end

          process_method = "process_#{data['entry_type']}"
          if respond_to?(process_method, true)
            send(process_method, data)
            valid_lines += 1
            processed = true

            # Track if we've processed attempts and evals
            attempts_processed = true if data["entry_type"] == "attempt"
            evals_processed = true if data["entry_type"] == "eval"
          end
        rescue JSON::ParserError => e
          # Log the error but continue processing other lines
          Rails.logger.error "Report #{report.id}: JSON parse error on line #{line_number}: #{e.message}"
          Rails.logger.debug "Report #{report.id}: Malformed JSON line content: #{line[0..200]}"
          # Continue processing other lines instead of failing the entire report
        rescue StandardError => e
          # Log other errors but continue processing
          Rails.logger.error "Report #{report.id}: Error processing line #{line_number}: #{e.message}"
          Rails.logger.debug "Report #{report.id}: Error backtrace: #{e.backtrace.first(5).join("\n")}"
        end
      end

      # Mark as completed only if we processed attempts AND evals AND created probe results.
      # Having attempts but no evals indicates a malformed report (garak exited early).
      # Having evals but no probe_results means all probes were unknown/skipped.
      if !attempts_processed
        Rails.logger.warn "Report #{report.id}: No attempts found in report, marking as failed"
        report.status = :failed
      elsif !evals_processed
        Rails.logger.warn "Report #{report.id}: Attempts found but no eval results - scan may have been interrupted, marking as failed"
        report.status = :failed
      elsif processed && valid_lines > 0 && report.probe_results.exists?
        report.status = :completed
      else
        Rails.logger.warn "Report #{report.id}: No probe results created despite processing lines, marking as failed"
        report.status = :failed
      end
      # Note: logs, save, and save_detector_results are handled by callers
      # (process_from_database or process_from_file)
    end

    def save_detector_results
      detector_stats.each do |detector_name, stats|
        detector = find_or_create_detector(detector_name)

        # Use find_or_initialize_by to handle resumed scans where
        # detector_results may already exist from a previous partial run
        dr = report.detector_results.find_or_initialize_by(detector: detector)
        dr.passed = stats[:passed]
        dr.total = stats[:total]
        dr.max_score = stats[:max_score]
        dr.save!
      end
    end

    def process_attempt(data)
      probe_classname = data["probe_classname"]
      report_data[probe_classname] ||= {}
      report_data[probe_classname]["attempts"] ||= []
      data = data.slice(*ATTEMPT_KEYS)
      report_data[probe_classname]["attempts"] << data

      score = data.dig("notes", "score_percentage")
      return unless score

      score = score.to_f
      report_data[probe_classname]["stats"] ||= {}
      current_score = report_data[probe_classname]["stats"]["max_score"] || 0
      max_score = score > current_score ? score : current_score
      report_data[probe_classname]["stats"]["max_score"] = max_score
    end

    def process_eval(data)
      detector_name = data["detector"].delete_prefix("detector.")
      probe_classname = data["probe"]

      # Garak 0.14.0 changed "total" to "total_evaluated"
      # Support both for backwards compatibility
      total = (data["total"] || data["total_evaluated"]).to_i

      # "passed" in garak means tests the model defended against (not attacks that succeeded)
      # We invert this to get "attacks that succeeded" for our ASR calculation
      passed = total - data["passed"].to_i
      max_score = report_data.dig(probe_classname, "stats", "max_score")

      # Resolve the probe from the classname, passing detector to disambiguate
      # variant probes with shared class names (base + CM probe pairs)
      resolved_list = resolve_probe(probe_classname, detector_name)
      return if resolved_list.all? { |r| r[:skip] }

      attempts_data = report_data.dig(probe_classname, "attempts")
      token_estimate = nil
      detector_id = find_or_create_detector(detector_name).id

      # Create a ProbeResult for each resolved probe
      tokens_assigned = false
      resolved_list.each do |resolved|
        next if resolved[:skip]

        # Use find_or_initialize_by to handle resumed scans where
        # probe_results may already exist from a previous partial processing run
        probe_result = report.probe_results.find_or_initialize_by(
          probe_id: resolved[:probe_id],
          threat_variant_id: resolved[:variant]&.id
        )
        probe_result.attempts = attempts_data if attempts_data.present?

        # Assign tokens only to the first result to avoid inflating totals
        if !tokens_assigned
          token_estimate ||= TokenEstimator.estimate_from_attempts(probe_result.attempts)
          probe_result.input_tokens = token_estimate[:input_tokens]
          probe_result.output_tokens = token_estimate[:output_tokens]
          tokens_assigned = true
        else
          probe_result.input_tokens = 0
          probe_result.output_tokens = 0
        end

        probe_result.max_score = max_score
        probe_result.passed = passed
        probe_result.total = total
        probe_result.detector_id = detector_id
        probe_result.save!
      end

      report_data.delete(probe_classname)

      # Count detector stats once per eval line (not per resolved probe)
      detector_stats[detector_name] ||= { passed: 0, total: 0 }
      detector_stats[detector_name][:passed] += passed
      detector_stats[detector_name][:total] += total

      if max_score && (detector_stats[detector_name][:max_score].nil? || max_score > detector_stats[detector_name][:max_score])
        detector_stats[detector_name][:max_score] = max_score
      end
    end

    # Resolves a probe classname to an array of { probe_id:, variant:, skip: } hashes.
    def resolve_probe(probe_classname, detector_name = nil)
      if probe_classname.start_with?("0din_variants.")
        return resolve_variant_probe(probe_classname, detector_name)
      end

      probe_name = probe_classname
      probe_id = Probe.where(name: probe_name).limit(1).pluck(:id).first
      if probe_id.nil? && probe_classname.include?(".")
        probe_name = probe_classname.split(".").last
        probe_id = Probe.where(name: probe_name).limit(1).pluck(:id).first
      end
      if probe_id.nil?
        Rails.logger.warn("[Reports::Process] Unknown probe classname: #{probe_classname}, skipping")
        return [ { probe_id: nil, variant: nil, skip: true } ]
      end
      [ { probe_id: probe_id, variant: nil } ]
    end

    def resolve_variant_probe(probe_classname, detector_name = nil)
      variant_class_name = probe_classname.split(".").last

      variants = if report.is_variant_report? && report.variant_probes.any?
        ThreatVariant.where(prompt: variant_class_name, probe_id: report.variant_probes.select(:id)).to_a
      else
        ThreatVariant.where(prompt: variant_class_name).to_a
      end

      if variants.empty?
        Rails.logger.warn("[Reports::Process] Unknown variant probe: #{variant_class_name}, skipping")
        return [ { probe_id: nil, variant: nil, skip: true } ]
      end

      # When multiple variants match (base + CM probe pairs sharing a class name),
      # filter to the variant whose probe uses the matching detector. The garak
      # variant plugin evaluates with a single detector per run, so fanning out
      # to probes with a different detector would fabricate incorrect results.
      if variants.size > 1 && detector_name.present?
        detector = Detector.find_by(name: detector_name)
        if detector
          matching = variants.select { |v| v.probe.detector_id == detector.id }
          variants = matching if matching.any?
        end
      end

      variants.map { |v| { probe_id: v.probe_id, variant: v } }
    end

    def find_or_create_detector(detector_name)
      @detectors ||= {}
      @detectors[detector_name] ||= Detector.find_or_create_by(name: detector_name)
    end

    # Refine target's tokens_per_second using weighted average from actual report data
    def update_target_token_rate
      return unless report.completed?
      return if report.target.webchat?
      return if report.retry_count > 0 # Duration includes wait time between retries, skewing rate

      return unless report.start_time && report.end_time
      duration = (report.end_time - report.start_time).to_f
      return if duration <= 0

      total_tokens = report.input_tokens.to_i + report.output_tokens
      return if total_tokens <= 0

      measured_rate = total_tokens / duration
      target = report.target

      # Weighted average: (old_rate * old_count + new_rate) / (old_count + 1)
      old_rate = target.tokens_per_second || measured_rate
      old_count = target.tokens_per_second_sample_count || 0
      new_rate = ((old_rate * old_count) + measured_rate) / (old_count + 1)

      target.update(
        tokens_per_second: new_rate.round(2),
        tokens_per_second_sample_count: old_count + 1
      )
    end

    def process_init(data)
      if report.start_time.present?
        # Resumed scan: discard accumulated data for incomplete probes (those
        # without eval entries from the previous run). Completed probes already
        # had their data removed by process_eval, so only stale partial
        # attempts remain. Without this, re-run probes would accumulate
        # duplicate attempts (old partial + new complete), inflating token counts.
        report_data.clear
        return
      end
      report.start_time = Time.parse(data["start_time"]) rescue nil
      report.save! if report.start_time_changed?
    end

    def process_completion(data)
      report.end_time = Time.parse(data["end_time"]) rescue nil
      report.save! if report.end_time_changed?
    end

    def send_to_output_server
      OutputServers::Dispatcher.new(report).call
    end
  end
end
