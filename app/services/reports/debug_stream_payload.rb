# frozen_string_literal: true

module Reports
  class DebugStreamPayload
    PREVIEW_LIMIT = 200
    RAW_TAIL_LINES = 100
    TIMELINE_TAIL_LIMIT = 500
    LOG_TAIL_LINES = 500
    ACTIVITY_PREVIEW_LIMIT = 22

    attr_reader :raw_report_data, :report

    def initialize(source)
      @raw_report_data = source if source.is_a?(RawReportData)
      @report = source if source.is_a?(Report) || report_like?(source)
      @report ||= @raw_report_data&.report
      @raw_report_data ||= @report&.raw_report_data
    end

    def call
      timeline = build_timeline
      raw_tail = build_raw_tail
      logs = build_logs

      {
        timeline: timeline,
        raw_tail: raw_tail,
        logs: logs[:data],
        log_metadata: logs.except(:data),
        activity: build_activity(timeline, logs),
        digest: compute_digest(timeline, raw_tail, logs)
      }
    end

    private

    def report_like?(source)
      source.respond_to?(:raw_report_data) && source.respond_to?(:report_debug_log)
    end

    def parsed_lines
      parsed_jsonl[:lines]
    end

    def parsed_jsonl
      @parsed_jsonl ||= parse_jsonl
    end

    def jsonl_data
      return @jsonl_data if defined?(@jsonl_data)

      @jsonl_data = raw_report_data&.jsonl_data.to_s
    end

    def parse_jsonl
      data = jsonl_data
      return { lines: [], tail: "" } if data.blank?

      lines = []
      tail = []

      data.each_line do |line|
        safe_line = line.to_s.dup.force_encoding(Encoding::UTF_8)
        safe_line = safe_line.scrub unless safe_line.valid_encoding?

        tail << safe_line
        tail.shift if tail.size > RAW_TAIL_LINES

        parsed = parse_line(safe_line)
        next if parsed.nil?

        lines << parsed
        lines.shift if lines.size > TIMELINE_TAIL_LIMIT
      end

      { lines: lines, tail: tail.join }
    end

    def parse_line(line)
      stripped = line.strip
      return nil if stripped.empty?

      data = JSON.parse(stripped)
      data if data.is_a?(Hash) && data["entry_type"]
    rescue JSON::ParserError, EncodingError => e
      report_id = raw_report_data&.report_id
      preview = truncate(stripped.to_s, PREVIEW_LIMIT)
      line_digest = Digest::SHA256.hexdigest(stripped.to_s)
      Rails.logger.warn(
        "[DebugStreamPayload] malformed JSONL report=#{report_id} " \
        "error=#{e.class}: #{e.message} line_bytes=#{stripped.to_s.bytesize} " \
        "line_sha256=#{line_digest}"
      )
      { "entry_type" => "_parse_error", "_raw" => preview }
    end

    def build_timeline
      parsed_lines.map { |line| timeline_entry(line) }
    end

    def timeline_entry(data)
      case data["entry_type"]
      when "init"
        { type: "init", start_time: data["start_time"] }
      when "attempt"
        {
          type: "attempt",
          probe: data["probe_classname"],
          uuid: data["uuid"],
          prompt_preview: truncate(extract_prompt(data), PREVIEW_LIMIT),
          output_preview: truncate(extract_output(data), PREVIEW_LIMIT)
        }
      when "eval"
        {
          type: "eval",
          probe: data["probe"],
          detector: data["detector"],
          passed: data["passed"],
          total: data["total_evaluated"]
        }
      when "completion"
        { type: "completion", end_time: data["end_time"] }
      when "_parse_error"
        { type: "_parse_error", raw: data["_raw"] }
      else
        { type: data["entry_type"] }
      end
    end

    def extract_prompt(data)
      TokenEstimator.extract_prompt_text(data["prompt"]).to_s
    end

    def extract_output(data)
      outputs = data["outputs"]
      return "" if outputs.nil?
      return outputs if outputs.is_a?(String)

      first = outputs.is_a?(Array) ? outputs.first : outputs
      TokenEstimator.extract_output_text(first).to_s
    end

    def build_raw_tail
      parsed_jsonl[:tail]
    end

    def build_logs
      debug_log = report&.report_debug_log
      return empty_log_payload if debug_log.nil?

      return live_tail_log_payload(debug_log) if live_tail_report? && debug_log.tail.present?
      return empty_log_payload if polling_report?
      return live_tail_log_payload(debug_log) if report&.stopped? && debug_log.tail.present?

      if debug_log.logs.present?
        return full_logs_payload(debug_log.logs.to_s)
      end

      empty_log_payload
    end

    def live_tail_log_payload(debug_log)
      {
        data: debug_log.tail.to_s,
        offset: debug_log.tail_offset,
        synced_at: debug_log.tail_synced_at,
        truncated: debug_log.tail_truncated,
        source: "live_tail",
        digest: debug_log.tail_digest.presence || Digest::MD5.hexdigest(debug_log.tail.to_s)
      }
    end

    def full_logs_payload(raw_logs)
      lines = raw_logs.lines
      truncated = lines.size > LOG_TAIL_LINES
      data = truncated ? lines.last(LOG_TAIL_LINES).join : raw_logs

      {
        data: data,
        offset: nil,
        synced_at: nil,
        truncated: truncated,
        source: "full_logs",
        digest: Digest::MD5.hexdigest(raw_logs)
      }
    end

    def empty_log_payload
      {
        data: "",
        offset: nil,
        synced_at: nil,
        truncated: false,
        source: "none",
        digest: nil
      }
    end

    def polling_report?
      report&.status.in?(Report::DEBUG_STREAM_POLLING_STATUSES)
    end

    def live_tail_report?
      report&.status.in?(Report::DEBUG_STREAM_LIVE_TAIL_STATUSES)
    end

    def activity_active?
      report&.status.in?((Report::DEBUG_BROADCAST_ACTIVE_STATUSES + %w[pending]).uniq)
    end

    def build_activity(timeline, logs)
      attempt_count = timeline.count { |entry| entry[:type] == "attempt" }
      eval_count = timeline.count { |entry| entry[:type] == "eval" }
      log_line_count = logs[:data].to_s.lines.count

      {
        active: activity_active?,
        status_label: activity_status_label,
        attempt_count: attempt_count,
        eval_count: eval_count,
        probe_count: activity_probe_count(timeline),
        entry_count: timeline.count + log_line_count,
        updated_at: activity_updated_at(logs),
        log_line_count: log_line_count,
        preview: activity_preview(timeline)
      }
    end

    def activity_status_label
      return "Your scan is running." if activity_active?
      return "Scan complete." if report&.completed?
      return "No scan status available." if report&.status.blank?

      "Scan #{report.status.tr("_", " ")}."
    end

    def activity_probe_count(timeline)
      timeline.filter_map do |entry|
        next unless entry[:type].in?(%w[attempt eval])

        entry[:probe].to_s.strip.presence
      end.uniq.count
    end

    def activity_updated_at(logs)
      return logs[:synced_at] if logs[:source] == "live_tail" && logs[:synced_at].present?
      return raw_report_data.updated_at if raw_report_data&.updated_at.present?

      report&.updated_at
    end

    def activity_preview(timeline)
      timeline.last(ACTIVITY_PREVIEW_LIMIT).map do |entry|
        preview = { type: entry[:type].to_s }
        probe = entry[:probe].to_s.strip
        detector = entry[:detector].to_s.strip

        preview[:probe] = probe if probe.present?
        preview[:detector] = detector if detector.present?
        preview
      end
    end

    def compute_digest(timeline, raw_tail, logs)
      has_raw_data = jsonl_data.present?
      has_log_data = logs[:data].present?
      return nil unless has_raw_data || has_log_data

      Digest::MD5.hexdigest({
        timeline: timeline,
        raw_tail: raw_tail,
        logs: logs[:data],
        log_offset: logs[:offset],
        log_synced_at: digest_timestamp(logs[:synced_at]),
        log_truncated: logs[:truncated],
        log_source: logs[:source],
        log_digest: logs[:digest]
      }.to_json)
    end

    def digest_timestamp(value)
      return nil if value.blank?
      return value.iso8601(6) if value.respond_to?(:iso8601)

      value.to_s
    end

    def truncate(str, limit)
      return "" if str.nil?

      str.length > limit ? "#{str[0, limit]}..." : str
    end
  end
end
