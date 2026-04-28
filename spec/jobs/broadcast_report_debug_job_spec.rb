# frozen_string_literal: true

require "rails_helper"

RSpec.describe BroadcastReportDebugJob, type: :job do
  let(:company) { create(:company) }
  let(:target) { create(:target, company: company) }
  let(:scan) { create(:complete_scan, company: company) }
  let(:report) { create(:report, :running, company: company, target: target, scan: scan) }

  before do
    @original_cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    allow_any_instance_of(ToastNotifier).to receive(:call)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  after do
    Rails.cache = @original_cache_store
  end

  def raw_jsonl(probe_name = "probe.Alpha")
    JSON.generate(entry_type: "attempt", probe_classname: probe_name, uuid: SecureRandom.uuid)
  end

  def cache_digest(report)
    payload = Reports::DebugStreamPayload.new(report.reload).call
    Rails.cache.write(
      described_class.digest_cache_key(report.id),
      described_class.new.send(:broadcast_digest, report, payload),
      expires_in: 5.minutes
    )
  end

  def cache_fingerprint(report)
    fingerprint = Reports::DebugStreamFingerprint.new(report.reload).call

    Rails.cache.write(
      described_class.fingerprint_cache_key(report.id),
      fingerprint[:digest],
      expires_in: 5.minutes
    )
  end

  def clear_test_jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ActiveJob::Base.queue_adapter.performed_jobs.clear
  end

  def render_partial(partial, payload)
    ActsAsTenant.with_tenant(company) do
      ApplicationController.render(
        partial: partial,
        locals: { report: report, payload: payload }
      )
    end
  end

  describe "#perform" do
    it "only enqueues one poller while a poller lease is active" do
      expect(Reports::DebugWatcher.refresh_and_enqueue(report)).to be(true)
      expect(Reports::DebugWatcher.refresh_and_enqueue(report)).to be(false)

      jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
      expect(jobs.count { |job| job[:job] == described_class }).to eq(1)
    end

    it "exits without broadcasting or re-enqueuing when no watcher exists" do
      create(:raw_report_data, report: report, jsonl_data: raw_jsonl)

      expect {
        described_class.new.perform(report.id)
      }.not_to have_enqueued_job(described_class)

      expect(Turbo::StreamsChannel).not_to have_received(:broadcast_replace_to)
    end

    it "broadcasts a changed payload and caches the digest" do
      Reports::DebugWatcher.refresh(report.id)
      create(:raw_report_data, report: report, jsonl_data: raw_jsonl)

      described_class.new.perform(report.id)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).with(
        Reports::DebugWatcher.stream_name(report),
        target: "report-debug-stream-content",
        partial: "admin/reports/debug_panel_stream",
        locals: hash_including(report: report, payload: hash_including(:timeline, :logs, :log_metadata, :activity, :digest))
      )
      expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).with(
        Reports::DebugWatcher.stream_name(report),
        target: "report-activity-stream-summary",
        partial: "admin/reports/activity_stream_summary",
        locals: hash_including(report: report, payload: hash_including(:activity))
      )
      expect(Rails.cache.read(described_class.digest_cache_key(report.id))).to be_present
      expect(Rails.cache.read(described_class.fingerprint_cache_key(report.id))).to be_present
    end

    it "does not advance caches when payload construction fails" do
      Reports::DebugWatcher.refresh(report.id)
      create(:raw_report_data, report: report, jsonl_data: raw_jsonl)
      payload_builder = instance_double(Reports::DebugStreamPayload)

      allow(Reports::DebugStreamPayload).to receive(:new).and_return(payload_builder)
      allow(payload_builder).to receive(:call).and_raise(StandardError, "payload failed")

      expect {
        described_class.new.perform(report.id)
      }.to raise_error(StandardError, "payload failed")

      expect(Rails.cache.read(described_class.digest_cache_key(report.id))).to be_nil
      expect(Rails.cache.read(described_class.fingerprint_cache_key(report.id))).to be_nil
    end

    it "does not advance caches when broadcasting fails" do
      Reports::DebugWatcher.refresh(report.id)
      create(:raw_report_data, report: report, jsonl_data: raw_jsonl)

      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to).and_raise(StandardError, "broadcast failed")

      expect {
        described_class.new.perform(report.id)
      }.to raise_error(StandardError, "broadcast failed")

      expect(Rails.cache.read(described_class.digest_cache_key(report.id))).to be_nil
      expect(Rails.cache.read(described_class.fingerprint_cache_key(report.id))).to be_nil
    end

    it "skips broadcast when the digest has not changed" do
      Reports::DebugWatcher.refresh(report.id)
      create(:raw_report_data, report: report, jsonl_data: raw_jsonl)
      cache_digest(report)

      expect(Reports::DebugStreamPayload).to receive(:new).and_call_original

      described_class.new.perform(report.id)

      expect(Turbo::StreamsChannel).not_to have_received(:broadcast_replace_to)
    end

    it "skips payload construction for unchanged fingerprints but still re-enqueues polling reports" do
      Reports::DebugWatcher.refresh(report.id)
      create(:raw_report_data, report: report, jsonl_data: raw_jsonl)
      cache_fingerprint(report)

      expect(Reports::DebugStreamPayload).not_to receive(:new)

      expect {
        described_class.new.perform(report.id)
      }.to have_enqueued_job(described_class).with(report.id)

      expect(Turbo::StreamsChannel).not_to have_received(:broadcast_replace_to)
    end

    it "broadcasts when raw JSONL content changes" do
      Reports::DebugWatcher.refresh(report.id)
      raw_data = create(:raw_report_data, report: report, jsonl_data: raw_jsonl("probe.Before"))
      cache_digest(report)
      cache_fingerprint(report)
      raw_data.update!(jsonl_data: raw_jsonl("probe.After"))

      described_class.new.perform(report.id)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).at_least(:once)
    end

    it "broadcasts when only the report debug-log tail changes" do
      Reports::DebugWatcher.refresh(report.id)
      create(:raw_report_data, report: report, jsonl_data: raw_jsonl)
      debug_log = create(:report_debug_log, report: report, tail: "first tail\n", tail_digest: "tail-1")
      cache_digest(report)
      cache_fingerprint(report)
      debug_log.update!(tail: "first tail\nsecond tail\n", tail_digest: "tail-2", tail_synced_at: Time.current)

      described_class.new.perform(report.id)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).with(
        Reports::DebugWatcher.stream_name(report),
        hash_including(
          target: "report-debug-stream-content",
          locals: hash_including(
            payload: hash_including(
              logs: "first tail\nsecond tail\n",
              log_metadata: hash_including(source: "live_tail")
            )
          )
        )
      )
    end

    it "does not rebroadcast when only the report_debug_log row timestamp changes" do
      Reports::DebugWatcher.refresh(report.id)
      create(:raw_report_data, report: report, jsonl_data: raw_jsonl)
      debug_log = create(:report_debug_log, report: report, tail: "stable tail\n", tail_digest: "tail-stable")
      cache_digest(report)
      cache_fingerprint(report)
      debug_log.touch

      expect(Reports::DebugStreamPayload).not_to receive(:new)

      described_class.new.perform(report.id)

      expect(Turbo::StreamsChannel).not_to have_received(:broadcast_replace_to)
    end

    it "broadcasts final full logs after a report leaves a polling status" do
      Reports::DebugWatcher.refresh(report.id)
      create(:raw_report_data, report: report, jsonl_data: raw_jsonl)
      create(:report_debug_log, report: report, logs: "final full logs\n", tail: "live tail\n", tail_digest: "tail-live")
      cache_digest(report)
      cache_fingerprint(report)

      clear_test_jobs
      report.update!(status: :completed)
      described_class.new.perform(report.id)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).with(
        Reports::DebugWatcher.stream_name(report),
        hash_including(
          target: "report-debug-stream-content",
          locals: hash_including(
            payload: hash_including(
              logs: "final full logs\n",
              log_metadata: hash_including(source: "full_logs")
            )
          )
        )
      )
    end

    it "renders broadcast partials with the same locals used by the job" do
      create(:raw_report_data, report: report, jsonl_data: raw_jsonl("probe.Rendered"))
      create(:report_debug_log, report: report, tail: "rendered live tail\n", tail_digest: "tail-render")
      payload = Reports::DebugStreamPayload.new(report.reload).call

      debug_html = render_partial("admin/reports/debug_panel_stream", payload)
      summary_html = render_partial("admin/reports/activity_stream_summary", payload)

      expect(debug_html).to include("report-debug-stream-content")
      expect(debug_html).to include('data-debug-tabs-target="panel"')
      expect(debug_html).to include('data-tab="timeline"')
      expect(debug_html).to include('data-tab="raw"')
      expect(debug_html).to include('data-tab="logs"')
      expect(debug_html).to include("probe.Rendered")
      expect(debug_html).to include("rendered live tail")
      expect(summary_html).to include("report-activity-stream-summary")
      expect(summary_html).to include("Activity Stream")
      expect(summary_html).to include("1 attempt so far")
    end

    it "broadcasts status-only activity and re-enqueues when raw_report_data is missing" do
      Reports::DebugWatcher.refresh(report.id)

      expect {
        described_class.new.perform(report.id)
      }.to have_enqueued_job(described_class).with(report.id)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).with(
        Reports::DebugWatcher.stream_name(report),
        hash_including(
          target: "report-activity-stream-summary",
          locals: hash_including(payload: hash_including(activity: hash_including(active: true)))
        )
      )
    end

    it "polls pending, starting, running, and processing reports" do
      Report::DEBUG_STREAM_POLLING_STATUSES.each do |status|
        polling_report = create(:report, company: company, target: target, scan: scan, status: status)
        Reports::DebugWatcher.refresh(polling_report.id)

        expect {
          described_class.new.perform(polling_report.id)
        }.to have_enqueued_job(described_class).with(polling_report.id)

        clear_test_jobs
      end
    end

    it "does not re-enqueue terminal reports" do
      terminal_report = create(:report, :completed, company: company, target: target, scan: scan)
      Reports::DebugWatcher.refresh(terminal_report.id)

      expect {
        described_class.new.perform(terminal_report.id)
      }.not_to have_enqueued_job(described_class)
    end

    it "exits cleanly if the report disappears during reload" do
      Reports::DebugWatcher.refresh(report.id)
      create(:raw_report_data, report: report, jsonl_data: raw_jsonl)
      report_id = report.id

      allow_any_instance_of(Report).to receive(:reload) do |record|
        record.destroy! if record.id == report_id && !record.destroyed?
        raise ActiveRecord::RecordNotFound, "Couldn't find Report with id=#{report_id}" if record.id == report_id

        record
      end

      expect {
        expect {
          described_class.new.perform(report_id)
        }.not_to raise_error
      }.not_to have_enqueued_job(described_class)

      expect(Turbo::StreamsChannel).not_to have_received(:broadcast_replace_to)
    end
  end

  describe "status-change wiring" do
    it "enqueues a broadcast when a watched report status changes" do
      Reports::DebugWatcher.refresh(report.id)
      clear_test_jobs

      expect {
        report.update!(status: :processing)
      }.to have_enqueued_job(described_class).with(report.id)
    end

    it "enqueues a terminal broadcast even while the poller lease is active" do
      Reports::DebugWatcher.refresh(report.id)
      described_class.mark_poller_active(report.id)
      clear_test_jobs

      expect {
        report.update!(status: :completed)
      }.to have_enqueued_job(described_class).with(report.id)
    end

    it "does not enqueue when no watcher exists" do
      expect {
        report.update!(status: :processing)
      }.not_to have_enqueued_job(described_class)
    end

    it "schedules a delayed follow-up broadcast for stopped transitions" do
      Reports::DebugWatcher.refresh(report.id)

      expect {
        described_class.enqueue_status_change(report.id, "stopped")
      }.to have_enqueued_job(described_class).with(report.id).twice
    end

    it "schedules a delayed follow-up broadcast for failed transitions" do
      Reports::DebugWatcher.refresh(report.id)

      expect {
        described_class.enqueue_status_change(report.id, "failed")
      }.to have_enqueued_job(described_class).with(report.id).twice
    end

    it "schedules a delayed follow-up broadcast for interrupted transitions" do
      Reports::DebugWatcher.refresh(report.id)

      expect {
        described_class.enqueue_status_change(report.id, "interrupted")
      }.to have_enqueued_job(described_class).with(report.id).twice
    end

    it "does not schedule a follow-up broadcast for completed transitions" do
      Reports::DebugWatcher.refresh(report.id)

      expect {
        described_class.enqueue_status_change(report.id, "completed")
      }.to have_enqueued_job(described_class).with(report.id).once
    end

    it "schedules the follow-up broadcast with FINAL_TAIL_FOLLOWUP_DELAY" do
      Reports::DebugWatcher.refresh(report.id)

      described_class.enqueue_status_change(report.id, "stopped")

      delayed_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select do |job|
        job[:job] == described_class && job[:args].first == report.id && job[:at].present?
      end

      expect(delayed_jobs.size).to eq(1)
      expected_at = (Time.current + described_class::FINAL_TAIL_FOLLOWUP_DELAY).to_f
      expect(delayed_jobs.first[:at]).to be_within(2.0).of(expected_at)
    end
  end
end
