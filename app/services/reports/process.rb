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

          case data["entry_type"]
          when "init"
            process_init(data)
          when "attempt"
            process_attempt(data)
            attempts_processed = true
          when "eval"
            process_eval(data)
            evals_processed = true
          when "completion"
            process_completion(data)
          else
            next
          end

          valid_lines += 1
          processed = true
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
      # Having evals but no probe_results means all probes were unknown/skipped — treat as failed
      # so operators see the drift between the runtime probe catalog and the database.
      if !attempts_processed
        Rails.logger.warn "Report #{report.id}: No attempts found in report, marking as failed"
        report.status = :failed
      elsif !evals_processed
        Rails.logger.warn "Report #{report.id}: Attempts found but no eval results - scan may have been interrupted, marking as failed"
        report.status = :failed
      elsif processed && valid_lines > 0 && @probe_results_saved_this_run
        report.status = :completed
      else
        Rails.logger.warn "Report #{report.id}: No probe results created despite processing lines, marking as failed"
        report.status = :failed
      end
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

      # Resolve the probe from the classname (cached to avoid repeated queries)
      resolved = resolve_probe(probe_classname)
      if resolved[:skip]
        report_data.delete(probe_classname)
        return
      end

      # Use find_or_initialize_by to handle resumed scans where
      # probe_results may already exist from a previous partial processing run
      probe_result = report.probe_results.find_or_initialize_by(
        probe_id: resolved[:probe_id],
        threat_variant_id: resolved[:variant]&.id
      )
      attempts_data = report_data.dig(probe_classname, "attempts")
      if attempts_data.present?
        probe_result.attempts = attempts_data
        token_estimate = TokenEstimator.estimate_from_attempts(probe_result.attempts)
        probe_result.input_tokens = token_estimate[:input_tokens]
        probe_result.output_tokens = token_estimate[:output_tokens]
      end

      probe_result.max_score = max_score unless max_score.nil?

      # Multi-detector: keep the max passed across detectors; new_record?
      # ensures first eval always sets the detector even when passed=0.
      detector_id = find_or_create_detector(detector_name).id
      if passed > probe_result.passed.to_i || probe_result.new_record?
        probe_result.passed = passed
        probe_result.total = total
        probe_result.detector_id = detector_id
      end
      probe_result.any_detector_passed ||= passed.positive?
      probe_result.save!
      @probe_results_saved_this_run = true
      report_data.delete(probe_classname)

      detector_stats[detector_name] ||= { passed: 0, total: 0 }
      detector_stats[detector_name][:passed] += passed
      detector_stats[detector_name][:total] += total

      if max_score && (detector_stats[detector_name][:max_score].nil? || max_score > detector_stats[detector_name][:max_score])
        detector_stats[detector_name][:max_score] = max_score
      end
    end

    # Resolves a probe classname to a probe_id and optional variant.
    # Tries full classname first, then falls back to last segment for 0din probes.
    # Skips unknown probes with a warning.
    def resolve_probe(probe_classname)
      @resolved_probes ||= {}
      return @resolved_probes[probe_classname] if @resolved_probes.key?(probe_classname)

      result = resolve_probe_uncached(probe_classname)
      @resolved_probes[probe_classname] = result
    end

    def resolve_probe_uncached(probe_classname)
      # Variant probes: runtime emits "0din_variants.<VariantPrompt>" (see
      # script/garak_plugins/probes/0din_variants.py and VariantProbeMapper).
      # Map the variant prompt back to its base probe via ThreatVariant.
      if probe_classname.start_with?("0din_variants.")
        variant_prompt = probe_classname.split(".", 2).last

        scope = ThreatVariant.where(prompt: variant_prompt)
        scope = scope.where(probe_id: variant_probe_ids) if variant_probe_ids&.any?
        # Order deterministically — prompts are unique per probe at the DB level,
        # but the same prompt can exist across probes. Fall back to a stable pick
        # and warn so operators see any future data drift.
        matches = scope.order(:probe_id, :id).limit(2).to_a
        variant = matches.first

        unless variant
          Rails.logger.warn("Report #{report.id}: Unknown variant probe: #{variant_prompt}, skipping")
          return { probe_id: nil, variant: nil, skip: true }
        end

        if matches.size > 1
          Rails.logger.warn("Report #{report.id}: Ambiguous variant prompt #{variant_prompt} matches multiple ThreatVariants; picked probe_id=#{variant.probe_id}")
        end

        return { probe_id: variant.probe_id, variant: variant }
      end

      # Standard probes: try full classname, then fall back to last segment
      # for any dotted name (e.g., "0din.Foo" → "Foo", "dan.DAN_Jailbreak" → "DAN_Jailbreak").
      probe_id = Probe.where(name: probe_classname).limit(1).pluck(:id).first
      if probe_id.nil? && probe_classname.include?(".")
        probe_name = probe_classname.split(".").last
        probe_id = Probe.where(name: probe_name).limit(1).pluck(:id).first
      end

      if probe_id.nil?
        Rails.logger.warn("Report #{report.id}: Unknown probe classname: #{probe_classname}, skipping")
        return { probe_id: nil, variant: nil, skip: true }
      end

      { probe_id: probe_id, variant: nil }
    end

    def find_or_create_detector(detector_name)
      @detectors ||= {}
      @detectors[detector_name] ||= Detector.find_or_create_by(name: detector_name)
    end

    def variant_probe_ids
      return @variant_probe_ids if defined?(@variant_probe_ids)

      @variant_probe_ids = report.is_variant_report? ? report.variant_probes.pluck(:id) : nil
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
      begin
        report.start_time = Time.parse(data["start_time"])
      rescue ArgumentError, TypeError => e
        Rails.logger.warn("Report #{report.id}: invalid start_time '#{data['start_time']}': #{e.message}")
        report.start_time = nil
      end
      report.save! if report.start_time_changed?
    end

    def process_completion(data)
      begin
        report.end_time = Time.parse(data["end_time"])
      rescue ArgumentError, TypeError => e
        Rails.logger.warn("Report #{report.id}: invalid end_time '#{data['end_time']}': #{e.message}")
        report.end_time = nil
      end
      report.save! if report.end_time_changed?
    end

    def send_to_output_server
      OutputServers::Dispatcher.new(report).call
    end
  end
end
