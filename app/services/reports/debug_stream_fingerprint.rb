# frozen_string_literal: true

module Reports
  class DebugStreamFingerprint
    SELECT_COLUMNS = [
      "reports.id",
      "reports.status",
      "reports.updated_at AS report_updated_at",
      "raw_report_data.id AS raw_report_data_id",
      "raw_report_data.updated_at AS raw_report_data_updated_at",
      "octet_length(raw_report_data.jsonl_data) AS raw_jsonl_bytes",
      "report_debug_logs.id AS report_debug_log_id",
      "report_debug_logs.tail_offset AS tail_offset",
      "report_debug_logs.tail_digest AS tail_digest",
      "report_debug_logs.tail_synced_at AS tail_synced_at",
      "report_debug_logs.tail_truncated AS tail_truncated"
    ].freeze

    def initialize(source)
      @report_id = source.respond_to?(:id) ? source.id : source
    end

    def call
      return nil if report_id.blank?

      record = fingerprint_record
      return nil if record.nil?

      metadata = fingerprint_metadata(record)
      metadata.merge(digest: digest(metadata))
    end

    private

    attr_reader :report_id

    def fingerprint_record
      Report
        .left_joins(:raw_report_data, :report_debug_log)
        .select(*SELECT_COLUMNS)
        .find_by(id: report_id)
    end

    def fingerprint_metadata(record)
      {
        report_id: record.id,
        status: record.status,
        report_updated_at: timestamp_attribute(record, "report_updated_at"),
        raw_report_data_id: integer_attribute(record, "raw_report_data_id"),
        raw_report_data_updated_at: timestamp_attribute(record, "raw_report_data_updated_at"),
        raw_jsonl_bytes: integer_attribute(record, "raw_jsonl_bytes"),
        report_debug_log_id: integer_attribute(record, "report_debug_log_id"),
        tail_offset: integer_attribute(record, "tail_offset"),
        tail_digest: record.read_attribute("tail_digest"),
        tail_synced_at: timestamp_attribute(record, "tail_synced_at"),
        tail_truncated: boolean_attribute(record, "tail_truncated")
      }
    end

    def digest(metadata)
      Digest::SHA256.hexdigest(metadata.to_json)
    end

    def integer_attribute(record, name)
      value = record.read_attribute(name)
      return nil if value.nil?

      value.to_i
    end

    def boolean_attribute(record, name)
      value = record.read_attribute(name)
      return nil if value.nil?

      ActiveModel::Type::Boolean.new.cast(value)
    end

    def timestamp_attribute(record, name)
      timestamp = record.read_attribute(name)
      return nil if timestamp.blank?
      return timestamp.iso8601(6) if timestamp.respond_to?(:iso8601)

      timestamp.to_s
    end
  end
end
