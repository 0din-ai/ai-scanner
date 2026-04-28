# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reports::DebugStreamFingerprint do
  let(:report) { create(:report, :running) }

  def jsonl(probe_name)
    JSON.generate(entry_type: "attempt", probe_classname: probe_name, uuid: SecureRandom.uuid)
  end

  def fingerprint(source = report)
    described_class.new(source).call
  end

  describe "#call" do
    it "returns stable metadata and digest when only the debug log row timestamp changes" do
      create(:raw_report_data, report: report, jsonl_data: jsonl("probe.Alpha"))
      debug_log = create(
        :report_debug_log,
        report: report,
        tail_digest: "tail-1",
        tail_offset: 120,
        tail_synced_at: Time.zone.local(2026, 4, 27, 12, 0, 0),
        tail_truncated: true
      )

      first = fingerprint
      debug_log.touch
      second = fingerprint

      expect(second).to eq(first)
      expect(second[:digest]).to match(/\A[a-f0-9]{64}\z/)
    end

    it "changes digest when raw JSONL metadata changes" do
      raw_data = create(:raw_report_data, report: report, jsonl_data: jsonl("probe.Before"))
      first = fingerprint

      raw_data.update_columns(
        jsonl_data: [ jsonl("probe.After"), jsonl("probe.AfterAgain") ].join("\n"),
        updated_at: 1.second.from_now
      )
      second = fingerprint

      expect(second[:raw_jsonl_bytes]).not_to eq(first[:raw_jsonl_bytes])
      expect(second[:raw_report_data_updated_at]).not_to eq(first[:raw_report_data_updated_at])
      expect(second[:digest]).not_to eq(first[:digest])
    end

    it "changes digest when live-tail digest metadata changes" do
      create(:raw_report_data, report: report, jsonl_data: jsonl("probe.Alpha"))
      debug_log = create(
        :report_debug_log,
        report: report,
        tail_digest: "tail-1",
        tail_offset: 120,
        tail_synced_at: Time.zone.local(2026, 4, 27, 12, 0, 0)
      )
      first = fingerprint

      debug_log.update_columns(
        tail_digest: "tail-2",
        tail_offset: 180,
        tail_synced_at: Time.zone.local(2026, 4, 27, 12, 1, 0)
      )
      second = fingerprint

      expect(second[:tail_digest]).to eq("tail-2")
      expect(second[:tail_offset]).to eq(180)
      expect(second[:digest]).not_to eq(first[:digest])
    end

    it "returns status and tail metadata when raw data is missing" do
      create(:report_debug_log, report: report, tail_digest: "tail-1", tail_offset: 44)

      result = fingerprint

      expect(result).to include(
        report_id: report.id,
        status: "running",
        raw_report_data_id: nil,
        raw_report_data_updated_at: nil,
        raw_jsonl_bytes: nil,
        tail_digest: "tail-1",
        tail_offset: 44
      )
      expect(result[:digest]).to match(/\A[a-f0-9]{64}\z/)
    end

    it "returns raw data metadata when the debug log is missing" do
      raw_data = create(:raw_report_data, report: report, jsonl_data: jsonl("probe.Alpha"))

      result = fingerprint

      expect(result).to include(
        report_id: report.id,
        status: "running",
        raw_report_data_id: raw_data.id,
        report_debug_log_id: nil,
        tail_offset: nil,
        tail_digest: nil,
        tail_synced_at: nil,
        tail_truncated: nil
      )
      expect(result[:raw_jsonl_bytes]).to eq(raw_data.jsonl_data.bytesize)
      expect(result[:raw_report_data_updated_at]).to be_present
      expect(result[:digest]).to match(/\A[a-f0-9]{64}\z/)
    end

    it "returns nil when the report is missing" do
      expect(described_class.new(Report.maximum(:id).to_i + 1).call).to be_nil
      expect(described_class.new(nil).call).to be_nil
    end

    it "selects joined scalar metadata without selecting raw JSONL or log text columns" do
      create(:raw_report_data, report: report, jsonl_data: jsonl("probe.Alpha"))
      create(:report_debug_log, report: report, logs: "full logs\n", tail: "live tail\n", tail_digest: "tail-1")
      sql_statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
        sql_statements << payload[:sql] if payload[:name] == "Report Load"
      end

      fingerprint(report.id)

      sql = sql_statements.find { |statement| statement.include?("raw_report_data") && statement.include?("report_debug_logs") }
      expect(sql).to include("LEFT OUTER JOIN")
      expect(sql).to include("octet_length(raw_report_data.jsonl_data)")
      expect(sql).not_to match(/raw_report_data\.jsonl_data\s+AS/i)
      expect(sql).not_to match(/report_debug_logs\.logs\b/i)
      expect(sql).not_to match(/report_debug_logs\.tail\b/i)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end
