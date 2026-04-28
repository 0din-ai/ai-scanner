# frozen_string_literal: true

require "rails_helper"

RSpec.describe RetryInterruptedReportsJob, type: :job do
  let(:target) { create(:target, status: "good") }
  let(:bad_target) { create(:target, status: "bad") }
  let(:scan) { create(:complete_scan) }

  before do
    allow_any_instance_of(ToastNotifier).to receive(:call)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  describe "#perform" do
    describe "basic retry behavior" do
      it "moves interrupted reports back to pending after stabilization delay" do
        report = create(:report, target: target, scan: scan, status: :interrupted, retry_count: 0, updated_at: 1.minute.ago)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("pending")
        expect(report.retry_count).to eq(1)
        expect(report.last_retry_at).to be_within(5.seconds).of(Time.current)
      end

      it "increments retry_count on each retry" do
        report = create(:report, target: target, scan: scan, status: :interrupted, retry_count: 1, updated_at: 1.minute.ago)

        described_class.new.perform

        report.reload
        expect(report.retry_count).to eq(2)
      end

      it "resets heartbeat_at for fresh start" do
        report = create(:report, target: target, scan: scan, status: :interrupted, heartbeat_at: 5.minutes.ago, updated_at: 1.minute.ago)

        described_class.new.perform

        report.reload
        expect(report.heartbeat_at).to be_nil
      end

      it "clears stale pid on retry" do
        report = create(:report, target: target, scan: scan, status: :interrupted, pid: 12345, heartbeat_at: 5.minutes.ago, updated_at: 1.minute.ago)

        described_class.new.perform

        report.reload
        expect(report.pid).to be_nil
      end

      it "clears stale live tail on retry" do
        report = create(:report, target: target, scan: scan, status: :interrupted, updated_at: 1.minute.ago)
        debug_log = create(:report_debug_log, report: report, tail: "previous attempt tail\n", tail_offset: 256, tail_digest: "old-tail", tail_synced_at: 1.minute.ago, tail_truncated: true)

        described_class.new.perform

        debug_log.reload
        expect(report.reload.status).to eq("pending")
        expect(debug_log.tail).to be_nil
        expect(debug_log.tail_offset).to eq(0)
        expect(debug_log.tail_digest).to be_nil
        expect(debug_log.tail_synced_at).to be_nil
        expect(debug_log.tail_truncated).to be(false)
      end

      it "appends retry log message" do
        report = create(:report, target: target, scan: scan, status: :interrupted, logs: "Previous log", retry_count: 0, updated_at: 1.minute.ago)

        described_class.new.perform

        report.reload
        expect(report.logs).to include("Previous log")
        expect(report.logs).to include("Auto-retry 1:")
        expect(report.logs).to include("Requeued after interruption")
      end
    end

    describe "stabilization delay" do
      it "does not retry reports within stabilization delay" do
        report = create(:report, target: target, scan: scan, status: :interrupted, retry_count: 0, updated_at: 10.seconds.ago)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("interrupted")
        expect(report.retry_count).to eq(0)
      end

      it "retries reports after stabilization delay" do
        report = create(:report, target: target, scan: scan, status: :interrupted, retry_count: 0, updated_at: 1.minute.ago)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("pending")
      end

      it "has 30 second stabilization delay" do
        expect(described_class::STABILIZATION_DELAY).to eq(30.seconds)
      end
    end

    describe "target status checking" do
      it "skips reports with bad target status" do
        report = create(:report, target: bad_target, scan: scan, status: :interrupted, retry_count: 0, updated_at: 1.minute.ago)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("interrupted")
        expect(report.retry_count).to eq(0)
      end

      it "retries reports with good target status" do
        report = create(:report, target: target, scan: scan, status: :interrupted, retry_count: 0, updated_at: 1.minute.ago)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("pending")
      end
    end

    describe "status filtering" do
      it "only processes interrupted reports" do
        pending_report = create(:report, target: target, scan: scan, status: :pending, updated_at: 1.minute.ago)
        running_report = create(:report, target: target, scan: scan, status: :running, heartbeat_at: Time.current, updated_at: 1.minute.ago)
        failed_report = create(:report, target: target, scan: scan, status: :failed, updated_at: 1.minute.ago)
        interrupted_report = create(:report, target: target, scan: scan, status: :interrupted, retry_count: 0, updated_at: 1.minute.ago)

        described_class.new.perform

        expect(pending_report.reload.status).to eq("pending")
        expect(running_report.reload.status).to eq("running")
        expect(failed_report.reload.status).to eq("failed")
        expect(interrupted_report.reload.status).to eq("pending")
      end
    end

    describe "multiple reports" do
      it "processes multiple interrupted reports" do
        report1 = create(:report, target: target, scan: scan, status: :interrupted, retry_count: 0, updated_at: 1.minute.ago)
        report2 = create(:report, target: target, scan: scan, status: :interrupted, retry_count: 1, updated_at: 1.minute.ago)

        described_class.new.perform

        expect(report1.reload.status).to eq("pending")
        expect(report1.retry_count).to eq(1)
        expect(report2.reload.status).to eq("pending")
        expect(report2.retry_count).to eq(2)
      end

      it "handles mix of good and bad target reports" do
        good_report = create(:report, target: target, scan: scan, status: :interrupted, retry_count: 0, updated_at: 1.minute.ago)
        bad_report = create(:report, target: bad_target, scan: scan, status: :interrupted, retry_count: 0, updated_at: 1.minute.ago)

        described_class.new.perform

        expect(good_report.reload.status).to eq("pending")
        expect(bad_report.reload.status).to eq("interrupted")
      end
    end

    describe "race conditions" do
      it "skips report if status changed during processing" do
        report = create(:report, target: target, scan: scan, status: :interrupted, retry_count: 0, updated_at: 1.minute.ago)

        # Simulate status change after query but before update
        allow_any_instance_of(Report).to receive(:reload) do |r|
          r.status = :running if r.id == report.id
          r
        end

        described_class.new.perform

        # Guard clause should prevent the job from modifying the DB record
        expect(Report.find(report.id).status).to eq("interrupted")
      end
    end
  end

  describe "queue configuration" do
    it "uses default queue" do
      expect(described_class.new.queue_name).to eq("default")
    end
  end
end
