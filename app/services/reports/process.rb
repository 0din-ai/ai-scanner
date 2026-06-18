module Reports
  class Process
    ATTEMPT_KEYS = %w[uuid prompt outputs notes messages].freeze
    EVAL_KEYS = %w[detector passed total_evaluated probe].freeze

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
      report.update!(status: :processing)

      Report.transaction do
        process_jsonl_data(@raw_data.jsonl_data, mark_processing: false)

        persist_final_logs
        apply_failure_metadata
        save_detector_results
        update_target_token_rate

        @raw_data.destroy!
        report.save!
      end
      Rails.logger.info("Report #{id}: Processed from database, raw_report_data deleted")
    end

    def persist_final_logs
      final_logs = current_run_final_logs
      return if final_logs.nil? && report.report_debug_log.nil?
      return if final_logs.nil? && preserve_existing_logs_without_final_logs?

      report.logs = final_logs
    end

    def current_run_final_logs
      return @current_run_final_logs if defined?(@current_run_final_logs)

      @current_run_final_logs = @raw_data.logs_data.presence || report.report_debug_log&.tail.presence
    end

    def preserve_existing_logs_without_final_logs?
      report.retry_count.to_i.positive? && report.logs.present?
    end

    def apply_failure_metadata
      failure = FailureClassifier.new(report, logs: current_run_failure_logs).call
      if failure.failed? && !completed_scan_with_clean_exit?
        report.status = :failed
        report.failure_code = failure.code
        report.failure_message = failure.message
        report.failure_details = failure.details
      elsif report.failed?
        report.failure_code = "scan_incomplete_results"
        report.failure_message = "The scan exited before producing a complete set of results."
        report.failure_details = {}
      else
        clear_failure_metadata
      end
    end

    # A report whose results are complete (process_jsonl_data set :completed) AND whose
    # run log shows a clean garak completion must not be turned into a failure by trailing
    # log noise (a post-scan report-digest error, or a transient provider status garak
    # retried past). Genuine failures (incomplete results, or a non-clean exit) are unaffected.
    def completed_scan_with_clean_exit?
      report.completed? && Reports::FailureClassifier.cleanly_completed?(current_run_failure_logs)
    end

    def current_run_failure_logs
      return @current_run_failure_logs if defined?(@current_run_failure_logs)

      @current_run_failure_logs = @raw_data.logs_data.presence || current_run_tail_failure_logs
    end

    def current_run_tail_failure_logs
      return if report.retry_count.to_i.positive?

      report.report_debug_log&.tail.presence
    end

    def clear_failure_metadata
      report.failure_code = nil
      report.failure_message = nil
      report.failure_details = {}
    end

    def process_jsonl_data(jsonl_string, mark_processing: true)
      report.update!(status: :processing) if mark_processing

      processed = false
      line_number = 0
      valid_lines = 0
      attempts_processed = false
      evals_processed = false
      completion_processed = false

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
          when "start_run setup"
            # Capture the eval threshold garak actually used for this run (from its
            # start_run setup config dump) so per-attempt success agrees with the
            # eval rows / ASR even if live EVALUATION_THRESHOLD config changed since.
            # Resumed scans concatenate multiple setup segments; clear the memo so
            # each segment's attempts re-resolve against that segment's threshold.
            @scan_eval_threshold = data["run.eval_threshold"]
            @eval_threshold = nil
            next
          when "init"
            process_init(data)
          when "attempt"
            process_attempt(data)
            attempts_processed = true
          when "eval"
            evals_processed = true if process_eval(data)
          when "completion"
            completion_processed = true if process_completion(data) == :processed
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

      # Mark as completed only if the report has all result and timing rows.
      # Having attempts/evals without completion means garak exited early after
      # producing partial data; keep those probe results for diagnosis, but do
      # not present the report as completed with an unknown duration.
      if !attempts_processed
        Rails.logger.warn "Report #{report.id}: No attempts found in report, marking as failed"
        report.status = :failed
      elsif !evals_processed
        Rails.logger.warn "Report #{report.id}: Attempts found but no eval results - scan may have been interrupted, marking as failed"
        report.status = :failed
      elsif !completion_processed
        Rails.logger.warn "Report #{report.id}: Attempts and eval results found but no completion row - scan exited before completion, marking as failed"
        report.status = :failed
      elsif report.start_time.blank? || report.end_time.blank?
        Rails.logger.warn "Report #{report.id}: Completion found but scan timing is incomplete, marking as failed"
        report.status = :failed
      elsif processed && valid_lines > 0
        report.status = :completed
      else
        Rails.logger.warn "Report #{report.id}: No probe results created despite processing lines, marking as failed"
        report.status = :failed
      end

      finalize_failed_report_timing
    end

    def finalize_failed_report_timing
      return unless report.failed?
      return if report.end_time.present?
      return if report.start_time.blank?

      candidate = terminal_log_end_time
      candidate = raw_data_updated_at if candidate.blank? || candidate < report.start_time
      candidate = Time.current if candidate.blank? || candidate < report.start_time
      return if candidate < report.start_time

      report.end_time = candidate
    end

    def terminal_log_end_time
      current_run_failure_logs.to_s.each_line.reverse_each do |line|
        next unless line.include?("Garak scan completed")

        timestamp = line.match(/\A(?<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?:,\d+)?/)&.[](:timestamp)
        next if timestamp.blank?

        parsed = Time.zone.parse(timestamp)
        return parsed if parsed
      rescue ArgumentError
        next
      end

      nil
    end

    def raw_data_updated_at
      @raw_data&.updated_at
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
      attack_succeeded = attempt_attack_succeeded(data["detector_results"])
      data = data.slice(*ATTEMPT_KEYS)
      data["attack_succeeded"] = attack_succeeded
      report_data[probe_classname]["attempts"] << data

      score = data.dig("notes", "score_percentage")
      return unless score

      score = score.to_f
      report_data[probe_classname]["stats"] ||= {}
      current_score = report_data[probe_classname]["stats"]["max_score"] || 0
      max_score = score > current_score ? score : current_score
      report_data[probe_classname]["stats"]["max_score"] = max_score
    end

    # True when any detector flagged any output as a successful attack
    # (score >= the configured eval threshold). nil when garak gave no detector
    # scores for the attempt (unknown — the view shows no status badge).
    def attempt_attack_succeeded(detector_results)
      return nil unless detector_results.is_a?(Hash)

      scores = detector_results.values.flatten.compact.map(&:to_f)
      return nil if scores.empty?

      scores.max >= eval_threshold
    end

    # The eval threshold for this report's target, so the per-attempt success
    # flag agrees with garak's eval rows / the ASR. Prefer the threshold garak
    # actually used for this run (captured from its start_run setup config dump);
    # fall back to the live env config only when raw data lacks that entry.
    # A run value of 0/0.0 is a valid threshold and is honored (only nil/false
    # are falsy in Ruby, so `0.0 || resolver` correctly keeps 0.0).
    def eval_threshold
      @eval_threshold ||= (@scan_eval_threshold || EnvironmentVariable.evaluation_threshold_for(report.target)).to_f
    end

    def process_eval(data)
      validation = GarakEvalRowValidator.call(data, require_probe_detector: true)
      unless validation.valid?
        Rails.logger.warn("Report #{report.id}: Invalid garak eval row skipped: #{validation.errors.join(', ')}")
        return false
      end

      detector_name = data["detector"].delete_prefix("detector.")
      probe_classname = data["probe"]
      total = validation.total_evaluated

      # "passed" in garak means tests the model defended against (not attacks that succeeded)
      # We invert this to get "attacks that succeeded" for our ASR calculation
      passed = total - validation.passed
      max_score = report_data.dig(probe_classname, "stats", "max_score")

      # Resolve the probe from the classname (cached to avoid repeated queries)
      resolved = resolve_probe(probe_classname)
      if resolved[:skip]
        report_data.delete(probe_classname)
        return false
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

      true
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
        report.save! if report.end_time_changed?
        return :rejected_invalid
      end

      report.save! if report.end_time_changed?
      :processed
    end

    def send_to_output_server
      return unless report.completed?

      OutputServers::Dispatcher.new(report).call
    end
  end
end
