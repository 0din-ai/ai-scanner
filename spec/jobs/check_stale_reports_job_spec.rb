# frozen_string_literal: true

require "rails_helper"

RSpec.describe CheckStaleReportsJob, type: :job do
  let(:target) { create(:target) }
  let(:scan) { create(:complete_scan) }

  before do
    allow_any_instance_of(ToastNotifier).to receive(:call)
    # Mock Turbo broadcast to avoid rendering partial in tests
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    # Stub the Solid Queue lookup - in test env we don't have Solid Queue tables
    # Default: return empty set (no pending jobs found)
    allow_any_instance_of(described_class).to receive(:pending_process_job_report_ids).and_return(Set.new)
  end

  describe "#perform" do
    describe "stale running reports" do
      it "marks report as interrupted when heartbeat is stale (first occurrence)" do
        stale_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :running, pid: 12345, heartbeat_at: stale_time, retry_count: 0)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("interrupted")
        expect(report.logs).to include("Interrupted:")
        expect(report.logs).to include("Scan stopped responding")
      end

      it "marks report as failed after max interrupt retries" do
        stale_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :running, pid: 12345, heartbeat_at: stale_time, retry_count: 3)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("failed")
        expect(report.logs).to include("after 3 retry attempts")
      end

      it "does not affect reports with recent heartbeat" do
        recent_time = 30.seconds.ago
        report = create(:report, target: target, scan: scan, status: :running, pid: 12345, heartbeat_at: recent_time)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("running")
      end

      it "does not affect reports with nil heartbeat_at (handled by never_started check)" do
        # Recent reports with nil heartbeat are NOT caught by stale check
        # They are handled by check_never_started_running_reports instead
        report = create(:report, target: target, scan: scan, status: :running, heartbeat_at: nil, updated_at: 30.seconds.ago)

        # Only run the stale check, not the full perform
        described_class.new.send(:check_stale_running_reports)

        report.reload
        expect(report.status).to eq("running")
      end

      it "does not affect non-running reports" do
        stale_time = 3.minutes.ago
        pending_report = create(:report, target: target, scan: scan, status: :pending, heartbeat_at: stale_time)
        completed_report = create(:report, target: target, scan: scan, status: :completed, heartbeat_at: stale_time)

        described_class.new.perform

        expect(pending_report.reload.status).to eq("pending")
        expect(completed_report.reload.status).to eq("completed")
      end

      it "appends interruption reason to existing logs" do
        stale_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :running, pid: 12345, heartbeat_at: stale_time, logs: "Previous log entry", retry_count: 0)

        described_class.new.perform

        report.reload
        expect(report.logs).to start_with("Previous log entry")
        expect(report.logs).to include("\n")
        expect(report.logs).to include("Interrupted:")
        expect(report.logs).to include("Scan stopped responding")
      end

      it "handles empty logs gracefully" do
        stale_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :running, pid: 12345, heartbeat_at: stale_time, logs: nil, retry_count: 0)

        described_class.new.perform

        report.reload
        expect(report.logs).to include("Interrupted:")
        expect(report.logs).to include("Scan stopped responding")
        expect(report.logs).not_to start_with("\n")
      end

      it "leaves existing logs intact when the live tail is blank" do
        stale_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :running, pid: 12345, heartbeat_at: stale_time, logs: "Previous log entry", retry_count: 0)
        report.report_debug_log.update!(tail: "")

        described_class.new.perform

        report.reload
        expect(report.status).to eq("interrupted")
        expect(report.logs).to start_with("Previous log entry")
        expect(report.logs).to include("Interrupted:")
      end

      it "promotes live tail before marking stale reports interrupted when logs are blank" do
        stale_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :running, pid: 12345, heartbeat_at: stale_time, logs: nil, retry_count: 0)
        report.report_debug_log.update!(tail: "garak line 1\ngarak line 2\n")

        described_class.new.perform

        report.reload
        expect(report.status).to eq("interrupted")
        expect(report.logs).to start_with("garak line 1\ngarak line 2")
        expect(report.logs.index("garak line 2")).to be < report.logs.index("Interrupted:")
      end

      it "appends live tail when the same tail text appears earlier but not at the end" do
        stale_time = 3.minutes.ago
        tail = "repeated garak output\nretry detail\n"
        existing_logs = "previous attempt\n#{tail}newer persisted line"
        report = create(
          :report,
          target: target,
          scan: scan,
          status: :running,
          pid: 12345,
          heartbeat_at: stale_time,
          logs: existing_logs,
          retry_count: 0
        )
        report.report_debug_log.update!(tail: tail)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("interrupted")
        expect(report.logs.scan(tail).size).to eq(2)
        expect(report.logs).to include("newer persisted line\n#{tail}")
        expect(report.logs).to include("Interrupted:")
      end

      it "does not duplicate live tail when logs already end with it" do
        stale_time = 3.minutes.ago
        tail = "garak line 1\ngarak line 2\n"
        existing_logs = "previous log\n#{tail.rstrip}"
        report = create(
          :report,
          target: target,
          scan: scan,
          status: :running,
          pid: 12345,
          heartbeat_at: stale_time,
          logs: existing_logs,
          retry_count: 0
        )
        report.report_debug_log.update!(tail: tail)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("interrupted")
        expect(report.logs.scan(tail.rstrip).size).to eq(1)
        expect(report.logs).to include("Interrupted:")
      end

      it "skips report if status changed during processing" do
        stale_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :running, pid: 12345, heartbeat_at: stale_time)

        # Simulate status change after query but before update
        allow_any_instance_of(Report).to receive(:reload) do |r|
          r.status = :completed if r.id == report.id
          r
        end

        described_class.new.perform

        # Guard clause should prevent the job from modifying the DB record
        expect(Report.find(report.id).status).to eq("running")
      end
    end

    describe "never-started running reports (nil heartbeat)" do
      it "marks report as interrupted when nil heartbeat and old enough (first occurrence)" do
        old_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :running, heartbeat_at: nil, updated_at: old_time, retry_count: 0)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("interrupted")
        expect(report.logs).to include("Interrupted:")
        expect(report.logs).to include("Scan process never started")
      end

      it "marks report as failed after max interrupt retries" do
        old_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :running, heartbeat_at: nil, updated_at: old_time, retry_count: 3)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("failed")
        expect(report.logs).to include("after 3 retry attempts")
      end

      it "promotes live tail before marking never-started reports failed" do
        old_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :running, heartbeat_at: nil, updated_at: old_time, retry_count: 3)
        create(:report_debug_log, report: report, tail: "startup stderr\n")

        described_class.new.perform

        report.reload
        expect(report.status).to eq("failed")
        expect(report.logs).to include("startup stderr")
        expect(report.logs.index("startup stderr")).to be < report.logs.index("after 3 retry attempts")
      end

      it "does not affect recent reports with nil heartbeat" do
        recent_time = 30.seconds.ago
        report = create(:report, target: target, scan: scan, status: :running, heartbeat_at: nil, updated_at: recent_time)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("running")
      end

      it "does not affect reports that have a heartbeat" do
        old_time = 3.minutes.ago
        recent_heartbeat = 30.seconds.ago
        report = create(:report, target: target, scan: scan, status: :running, pid: 12345, heartbeat_at: recent_heartbeat, updated_at: old_time)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("running")
      end

      it "does not affect non-running reports" do
        old_time = 3.minutes.ago
        pending_report = create(:report, target: target, scan: scan, status: :pending, heartbeat_at: nil, updated_at: old_time)
        completed_report = create(:report, target: target, scan: scan, status: :completed, heartbeat_at: nil, updated_at: old_time)

        described_class.new.perform

        expect(pending_report.reload.status).to eq("pending")
        expect(completed_report.reload.status).to eq("completed")
      end

      it "skips if heartbeat arrives during processing" do
        old_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :running, heartbeat_at: nil, updated_at: old_time)

        # Simulate heartbeat arriving after query but before update
        allow_any_instance_of(Report).to receive(:reload) do |r|
          if r.id == report.id
            r.heartbeat_at = Time.current
          end
          r
        end

        described_class.new.send(:check_never_started_running_reports)

        # Guard clause should prevent the job from modifying the DB record
        expect(Report.find(report.id).status).to eq("running")
      end
    end

    describe "orphaned running reports (pid cleared, heartbeat present)" do
      it "marks report as interrupted when running with nil pid and heartbeat present (first occurrence)" do
        report = create(:report, target: target, scan: scan, status: :running,
                        pid: nil, heartbeat_at: 1.minute.ago, updated_at: 3.minutes.ago, retry_count: 0)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("interrupted")
        expect(report.logs).to include("Interrupted:")
        expect(report.logs).to include("orphaned")
      end

      it "marks report as failed after max interrupt retries" do
        report = create(:report, target: target, scan: scan, status: :running,
                        pid: nil, heartbeat_at: 1.minute.ago, updated_at: 3.minutes.ago, retry_count: 3)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("failed")
        expect(report.logs).to include("after 3 retry attempts")
      end

      it "promotes live tail before marking orphaned reports interrupted" do
        report = create(:report, target: target, scan: scan, status: :running,
                        pid: nil, heartbeat_at: 1.minute.ago, updated_at: 3.minutes.ago, retry_count: 0)
        create(:report_debug_log, report: report, tail: "orphan stderr\n")

        described_class.new.perform

        report.reload
        expect(report.status).to eq("interrupted")
        expect(report.logs).to include("orphan stderr")
        expect(report.logs.index("orphan stderr")).to be < report.logs.index("Interrupted:")
      end

      it "does not affect running reports with a pid still set" do
        report = create(:report, target: target, scan: scan, status: :running,
                        pid: 12345, heartbeat_at: 1.minute.ago, updated_at: 3.minutes.ago)

        described_class.new.send(:check_orphaned_running_reports)

        report.reload
        expect(report.status).to eq("running")
      end

      it "does not affect running reports with nil heartbeat (handled by never-started check)" do
        report = create(:report, target: target, scan: scan, status: :running,
                        pid: nil, heartbeat_at: nil, updated_at: 3.minutes.ago)

        described_class.new.send(:check_orphaned_running_reports)

        report.reload
        expect(report.status).to eq("running")
      end

      it "does not affect recent orphaned reports within safety window" do
        report = create(:report, target: target, scan: scan, status: :running,
                        pid: nil, heartbeat_at: 30.seconds.ago, updated_at: 30.seconds.ago)

        described_class.new.send(:check_orphaned_running_reports)

        report.reload
        expect(report.status).to eq("running")
      end

      it "does not affect non-running reports" do
        report = create(:report, target: target, scan: scan, status: :pending,
                        pid: nil, heartbeat_at: 3.minutes.ago, updated_at: 3.minutes.ago)

        described_class.new.send(:check_orphaned_running_reports)

        report.reload
        expect(report.status).to eq("pending")
      end

      context "when raw_report_data exists (partial data from JournalSyncThread)" do
        it "still marks as interrupted since raw_report_data may be partial" do
          report = create(:report, target: target, scan: scan, status: :running,
                          pid: nil, heartbeat_at: 1.minute.ago, updated_at: 3.minutes.ago, retry_count: 0)
          create(:raw_report_data, report: report)

          described_class.new.perform

          report.reload
          expect(report.status).to eq("interrupted")
          expect(report.logs).to include("orphaned")
        end
      end

      context "when a pending ProcessReportJob exists (completed scan awaiting processing)" do
        it "skips the report instead of marking as orphaned" do
          report = create(:report, target: target, scan: scan, status: :running,
                          pid: nil, heartbeat_at: 1.minute.ago, updated_at: 3.minutes.ago, retry_count: 0)

          allow_any_instance_of(described_class).to receive(:pending_process_job_report_ids)
            .and_return(Set.new([ report.id ]))

          described_class.new.perform

          report.reload
          expect(report.status).to eq("running")
        end
      end
    end

    describe "stuck starting reports" do
      it "retries report when under max retries" do
        stuck_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :starting, retry_count: 0, updated_at: stuck_time)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("pending")
        expect(report.retry_count).to eq(1)
        expect(report.last_retry_at).to be_within(5.seconds).of(Time.current)
        expect(report.logs).to include("Retry 1:")
        expect(report.logs).to include("timed out")
      end

      it "increments retry_count on each retry" do
        stuck_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :starting, retry_count: 1, updated_at: stuck_time)

        described_class.new.perform

        report.reload
        expect(report.retry_count).to eq(2)
        expect(report.logs).to include("Retry 2:")
      end

      it "does not append stale live tail when retrying a stuck starting report" do
        stuck_time = 3.minutes.ago
        report = create(
          :report,
          target: target,
          scan: scan,
          status: :starting,
          logs: "previous retry audit",
          retry_count: 0,
          updated_at: stuck_time
        )
        debug_log = report.report_debug_log
        debug_log.update!(tail: "stale previous tail\n", tail_offset: 512, tail_digest: "stale")

        described_class.new.perform

        report.reload
        debug_log.reload
        expect(report.status).to eq("pending")
        expect(report.logs).to include("previous retry audit")
        expect(report.logs).to include("Retry 1:")
        expect(report.logs).not_to include("stale previous tail")
        expect(debug_log.tail).to be_nil
        expect(debug_log.tail_offset).to eq(0)
        expect(debug_log.tail_digest).to be_nil
      end

      it "marks as failed after max retries" do
        stuck_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :starting, retry_count: 3, updated_at: stuck_time)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("failed")
        expect(report.logs).to include("Failed after 3 start attempts")
      end

      it "does not append stale live tail before marking start-timeout reports failed" do
        stuck_time = 3.minutes.ago
        report = create(:report, target: target, scan: scan, status: :starting, retry_count: 3, updated_at: stuck_time)
        create(:report_debug_log, report: report, tail: "start timeout stderr\n")

        described_class.new.perform

        report.reload
        expect(report.status).to eq("failed")
        expect(report.logs).not_to include("start timeout stderr")
        expect(report.logs).to include("Failed after 3 start attempts")
      end

      it "does not affect starting reports within timeout" do
        recent_time = 30.seconds.ago
        report = create(:report, target: target, scan: scan, status: :starting, updated_at: recent_time)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("starting")
      end

      it "does not affect non-starting reports" do
        stuck_time = 3.minutes.ago
        running_report = create(:report, target: target, scan: scan, status: :running, pid: 12345, updated_at: stuck_time, heartbeat_at: Time.current)
        pending_report = create(:report, target: target, scan: scan, status: :pending, updated_at: stuck_time)

        described_class.new.perform

        expect(running_report.reload.status).to eq("running")
        expect(pending_report.reload.status).to eq("pending")
      end
    end

    describe "multiple reports" do
      it "processes multiple stale reports as interrupted" do
        stale_time = 3.minutes.ago
        report1 = create(:report, target: target, scan: scan, status: :running, pid: 12345, heartbeat_at: stale_time, retry_count: 0)
        report2 = create(:report, target: target, scan: scan, status: :running, pid: 12346, heartbeat_at: stale_time, retry_count: 0)

        described_class.new.perform

        expect(report1.reload.status).to eq("interrupted")
        expect(report2.reload.status).to eq("interrupted")
      end

      it "handles mix of stale running and stuck starting" do
        stale_time = 3.minutes.ago
        running_report = create(:report, target: target, scan: scan, status: :running, pid: 12345, heartbeat_at: stale_time, retry_count: 0)
        starting_report = create(:report, target: target, scan: scan, status: :starting, retry_count: 0, updated_at: stale_time)

        described_class.new.perform

        expect(running_report.reload.status).to eq("interrupted")
        expect(starting_report.reload.status).to eq("pending")
      end

      it "fails reports that exceed max retries while interrupting others" do
        stale_time = 3.minutes.ago
        fresh_report = create(:report, target: target, scan: scan, status: :running, pid: 12345, heartbeat_at: stale_time, retry_count: 0)
        maxed_report = create(:report, target: target, scan: scan, status: :running, pid: 12346, heartbeat_at: stale_time, retry_count: 3)

        described_class.new.perform

        expect(fresh_report.reload.status).to eq("interrupted")
        expect(maxed_report.reload.status).to eq("failed")
      end
    end
  end

  describe "constants" do
    it "has 2 minute heartbeat timeout" do
      expect(described_class::HEARTBEAT_TIMEOUT).to eq(2.minutes)
    end

    it "has 2 minute starting timeout" do
      expect(described_class::STARTING_TIMEOUT).to eq(2.minutes)
    end

    it "has max 3 start retries" do
      expect(described_class::MAX_START_RETRIES).to eq(3)
    end

    it "has max 3 interrupt retries" do
      expect(described_class::MAX_INTERRUPT_RETRIES).to eq(3)
    end
  end

  describe "queue configuration" do
    it "uses default queue" do
      expect(described_class.new.queue_name).to eq("default")
    end
  end
end
