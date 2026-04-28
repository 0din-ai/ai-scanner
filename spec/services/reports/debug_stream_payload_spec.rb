# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reports::DebugStreamPayload do
  let(:report) { create(:report) }

  def jsonl(*entries)
    entries.map { |entry| JSON.generate(entry) }.join("\n")
  end

  describe "#call" do
    it "builds timeline, raw tail, log, activity, and digest data from a report" do
      create(
        :raw_report_data,
        report: report,
        jsonl_data: jsonl(
          { entry_type: "init", start_time: "2026-04-27T12:00:00Z" },
          { entry_type: "attempt", probe_classname: "probe.Alpha", uuid: "a1", prompt: "hello", outputs: [ "world" ] }
        )
      )

      payload = described_class.new(report).call

      expect(payload).to include(:timeline, :raw_tail, :logs, :log_metadata, :activity, :digest)
      expect(payload[:timeline]).to include(
        { type: "init", start_time: "2026-04-27T12:00:00Z" },
        hash_including(type: "attempt", probe: "probe.Alpha", prompt_preview: "hello", output_preview: "world")
      )
      expect(payload[:raw_tail]).to include("probe.Alpha")
      expect(payload[:digest]).to match(/\A[a-f0-9]{32}\z/)
    end

    it "reads raw JSONL once per payload build" do
      raw_data = create(
        :raw_report_data,
        report: report,
        jsonl_data: jsonl(
          { entry_type: "init", start_time: "2026-04-27T12:00:00Z" },
          { entry_type: "attempt", probe_classname: "probe.Alpha", uuid: "a1" }
        )
      )

      expect(raw_data).to receive(:jsonl_data).once.and_call_original

      payload = described_class.new(raw_data).call

      expect(payload[:timeline]).to include(
        { type: "init", start_time: "2026-04-27T12:00:00Z" },
        hash_including(type: "attempt", probe: "probe.Alpha")
      )
      expect(payload[:digest]).to match(/\A[a-f0-9]{32}\z/)
    end

    it "returns status-only activity when raw data is missing" do
      payload = described_class.new(report).call

      expect(payload[:timeline]).to eq([])
      expect(payload[:raw_tail]).to eq("")
      expect(payload[:logs]).to eq("")
      expect(payload[:log_metadata]).to include(source: "none")
      expect(payload[:activity]).to include(status_label: "Your scan is running.", active: true)
      expect(payload[:digest]).to be_nil
    end

    it "uses live tails for statuses that can have current tails and hides stale full logs" do
      synced_at = Time.zone.local(2026, 4, 27, 12, 30, 0)
      create(
        :report_debug_log,
        report: report,
        logs: "previous final logs\n",
        tail: "fresh live tail\n",
        tail_offset: 42,
        tail_digest: "tail-digest",
        tail_synced_at: synced_at,
        tail_truncated: true
      )

      Report::DEBUG_STREAM_LIVE_TAIL_STATUSES.each do |status|
        report.update!(status: status)

        payload = described_class.new(report.reload).call

        expect(payload[:logs]).to eq("fresh live tail\n")
        expect(payload[:log_metadata]).to include(
          source: "live_tail",
          offset: 42,
          digest: "tail-digest",
          synced_at: synced_at,
          truncated: true
        )
      end
    end

    it "does not show stale live tails while a retry is still starting" do
      report.update!(status: :starting)
      create(:report_debug_log, report: report, logs: "previous final logs\n", tail: "stale live tail\n")

      payload = described_class.new(report.reload).call

      expect(payload[:logs]).to eq("")
      expect(payload[:log_metadata]).to include(source: "none")
    end

    it "does not show stale live tails while a retry is pending" do
      report.update!(status: :pending)
      create(:report_debug_log, report: report, logs: "previous final logs\n", tail: "stale live tail\n")

      payload = described_class.new(report.reload).call

      expect(payload[:logs]).to eq("")
      expect(payload[:log_metadata]).to include(source: "none")
    end

    it "returns no logs for polling reports before a live tail is synced" do
      report.update!(status: :processing)
      create(:report_debug_log, report: report, logs: "previous final logs\n")

      payload = described_class.new(report.reload).call

      expect(payload[:logs]).to eq("")
      expect(payload[:log_metadata]).to include(source: "none")
    end

    it "uses final full logs for terminal reports" do
      terminal_report = create(:report, :completed)
      full_logs = 200.times.map { |index| "line #{index + 1}\n" }.join
      create(:report_debug_log, report: terminal_report, logs: full_logs, tail: "stale live tail\n")

      payload = described_class.new(terminal_report.reload).call

      expect(payload[:logs].lines.length).to eq(200)
      expect(payload[:logs]).to include("line 200")
      expect(payload[:logs]).to include("line 1\n")
      expect(payload[:logs]).not_to include("stale live tail")
      expect(payload[:log_metadata]).to include(source: "full_logs", truncated: false)
      expect(payload[:digest]).to match(/\A[a-f0-9]{32}\z/)
    end

    it "uses the last live tail for stopped reports without final logs" do
      stopped_report = create(:report, status: :stopped)
      create(
        :report_debug_log,
        report: stopped_report,
        tail: "last live tail before stop\n",
        tail_offset: 128,
        tail_digest: "stopped-tail"
      )

      payload = described_class.new(stopped_report.reload).call

      expect(payload[:logs]).to eq("last live tail before stop\n")
      expect(payload[:log_metadata]).to include(source: "live_tail", offset: 128, digest: "stopped-tail")
    end

    it "uses the current stopped live tail before preserved retry logs" do
      stopped_report = create(:report, status: :stopped, retry_count: 1)
      create(
        :report_debug_log,
        report: stopped_report,
        logs: "previous attempt logs\n[2026-04-27 12:00:00] Auto-retry 1: Requeued after interruption",
        tail: "current stopped tail\n",
        tail_offset: 256,
        tail_digest: "current-stopped-tail"
      )

      payload = described_class.new(stopped_report.reload).call

      expect(payload[:logs]).to eq("current stopped tail\n")
      expect(payload[:logs]).not_to include("previous attempt logs")
      expect(payload[:log_metadata]).to include(source: "live_tail", offset: 256, digest: "current-stopped-tail")
    end

    it "logs malformed JSONL without copying raw prompt text into Rails logs" do
      allow(Rails.logger).to receive(:warn)
      create(:raw_report_data, report: report, jsonl_data: '{"entry_type":"attempt","prompt":"secret prompt"')

      payload = described_class.new(report).call

      expect(payload[:timeline]).to include(hash_including(type: "_parse_error"))
      expect(Rails.logger).to have_received(:warn).with(
        include("malformed JSONL", "line_bytes=", "line_sha256=")
      )
      expect(Rails.logger).not_to have_received(:warn).with(include("secret prompt"))
    end

    it "changes digest when only the live execution-log tail changes" do
      report.update!(status: :running)
      create(:raw_report_data, report: report, jsonl_data: jsonl({ entry_type: "init", start_time: "now" }))
      debug_log = create(:report_debug_log, report: report, tail: "first tail\n", tail_digest: "tail-1")

      first_digest = described_class.new(report.reload).call[:digest]
      debug_log.update!(tail: "second tail\n", tail_digest: "tail-2")
      second_digest = described_class.new(report.reload).call[:digest]

      expect(second_digest).not_to eq(first_digest)
    end

    it "bounds raw JSONL and parsed timeline tails" do
      total = described_class::TIMELINE_TAIL_LIMIT + 20
      create(
        :raw_report_data,
        report: report,
        jsonl_data: total.times.map { |index| JSON.generate(entry_type: "attempt", probe_classname: "probe.P#{index}", uuid: "u#{index}") }.join("\n")
      )

      payload = described_class.new(report).call

      expect(payload[:timeline].length).to eq(described_class::TIMELINE_TAIL_LIMIT)
      expect(payload[:timeline].first).to include(probe: "probe.P20")
      expect(payload[:raw_tail].lines.length).to eq(described_class::RAW_TAIL_LINES)
    end
  end

  describe "full logs truncation" do
    let(:report) { create(:report, :completed) }

    it "caps full logs to LOG_TAIL_LINES and sets truncated metadata" do
      long_log = (1..600).map { |i| "line #{i}" }.join("\n") + "\n"
      create(:report_debug_log, report: report, logs: long_log)

      result = described_class.new(report.reload).call

      expect(result[:log_metadata][:source]).to eq("full_logs")
      expect(result[:log_metadata][:truncated]).to be true
      expect(result[:logs].lines.count).to eq(described_class::LOG_TAIL_LINES)
      expect(result[:logs]).to include("line 600")
      expect(result[:logs]).not_to include("line 100")
    end

    it "leaves shorter full logs untruncated" do
      short_log = (1..10).map { |i| "line #{i}" }.join("\n") + "\n"
      create(:report_debug_log, report: report, logs: short_log)

      result = described_class.new(report.reload).call

      expect(result[:log_metadata][:source]).to eq("full_logs")
      expect(result[:log_metadata][:truncated]).to be false
      expect(result[:logs].lines.count).to eq(10)
    end
  end
end
