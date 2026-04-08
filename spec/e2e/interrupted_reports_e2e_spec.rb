# frozen_string_literal: true

require "rails_helper"

# E2E Tests for Interrupted Reports Feature
#
# These tests verify the complete end-to-end behavior of the interrupted reports
# recovery system, including:
# - Database state transitions
# - Job execution and scheduling
# - Log message formatting
# - Multi-pod safety guarantees
#
# Run with: RAILS_ENV=test bundle exec rspec spec/e2e/interrupted_reports_e2e_spec.rb
RSpec.describe "Interrupted Reports E2E", type: :feature do
  # Use transactions for test isolation
  let(:target) { create(:target, :good) }
  let(:bad_target) { create(:target, :bad) }
  let(:scan) { create(:complete_scan) }

  before do
    # Suppress notifications and broadcasts during tests
    allow_any_instance_of(ToastNotifier).to receive(:call)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    allow(Turbo::StreamsChannel).to receive(:broadcast_append_to)
    allow(Turbo::StreamsChannel).to receive(:broadcast_remove_to)
    # Don't actually run garak scans
    allow_any_instance_of(RunGarakScan).to receive(:call)
    # Stub the Solid Queue lookup - in test env we don't have Solid Queue tables
    allow_any_instance_of(CheckStaleReportsJob).to receive(:pending_process_job_report_ids).and_return(Set.new)
  end

  describe "Scenario 1: Pod crash during scan execution" do
    it "recovers a scan that was running when pod crashed" do
      # Simulate: A scan was running, pod crashed, heartbeat stopped
      report = create(:report,
        target: target,
        scan: scan,
        status: :running,
        pid: 12345,
        heartbeat_at: 5.minutes.ago, # Stale heartbeat
        retry_count: 0,
        logs: "[2025-01-01 10:00:00] Scan started\n[2025-01-01 10:01:00] Processing probes..."
      )

      initial_logs = report.logs

      # Step 1: CheckStaleReportsJob detects the stale report
      expect {
        CheckStaleReportsJob.new.perform
      }.to change { report.reload.status }.from("running").to("interrupted")

      # Verify interruption was logged
      expect(report.logs).to include(initial_logs)
      expect(report.logs).to include("Interrupted:")
      expect(report.logs).to include("Scan stopped responding")
      expect(report.logs).to match(/\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]/) # Timestamp format

      # Step 2: Immediately after, retry job runs but stabilization delay prevents retry
      RetryInterruptedReportsJob.new.perform
      expect(report.reload.status).to eq("interrupted") # Still interrupted

      # Step 3: After stabilization delay (simulate by updating timestamp)
      report.update_column(:updated_at, 35.seconds.ago)

      # Step 4: RetryInterruptedReportsJob moves to pending
      expect {
        RetryInterruptedReportsJob.new.perform
      }.to change { report.reload.status }.from("interrupted").to("pending")

      expect(report.retry_count).to eq(1)
      expect(report.last_retry_at).to be_within(5.seconds).of(Time.current)
      expect(report.heartbeat_at).to be_nil # Reset for fresh start
      expect(report.pid).to be_nil # Stale PID cleared
      expect(report.logs).to include("Auto-retry 1:")
      expect(report.logs).to include("Requeued after interruption")

      # Step 5: StartPendingScansJob picks it up
      # Need to also age last_retry_at to pass exponential backoff check (2^1 = 2 min)
      report.update_column(:last_retry_at, 3.minutes.ago)
      allow(SettingsService).to receive(:parallel_scans_limit).and_return(5)

      expect {
        StartPendingScansJob.new.perform
      }.to change { report.reload.status }.from("pending").to("starting")
    end
  end

  describe "Scenario 2: Scan never started (process spawn failure)" do
    it "recovers a scan that never received a heartbeat" do
      # Simulate: Report moved to running but garak process never started
      report = create(:report,
        target: target,
        scan: scan,
        status: :running,
        heartbeat_at: nil, # Never received heartbeat
        updated_at: 5.minutes.ago,
        retry_count: 0
      )

      # CheckStaleReportsJob detects never-started scan
      expect {
        CheckStaleReportsJob.new.perform
      }.to change { report.reload.status }.from("running").to("interrupted")

      expect(report.logs).to include("Scan process never started")
    end
  end

  describe "Scenario 3: Stuck in starting state" do
    it "recovers a scan stuck in starting state" do
      # Simulate: Report claimed for starting but never transitioned to running
      report = create(:report,
        target: target,
        scan: scan,
        status: :starting,
        updated_at: 5.minutes.ago,
        retry_count: 0
      )

      # CheckStaleReportsJob retries stuck starting scan
      expect {
        CheckStaleReportsJob.new.perform
      }.to change { report.reload.status }.from("starting").to("pending")

      expect(report.retry_count).to eq(1)
      expect(report.logs).to include("Retry 1:")
      expect(report.logs).to include("timed out after")
    end
  end

  describe "Scenario 4: Repeated failures exhaust retries" do
    it "fails permanently after MAX_INTERRUPT_RETRIES" do
      # Simulate: Scan has been interrupted 3 times already
      report = create(:report,
        target: target,
        scan: scan,
        status: :running,
        pid: 12345,
        heartbeat_at: 5.minutes.ago,
        retry_count: CheckStaleReportsJob::MAX_INTERRUPT_RETRIES, # 3
        logs: "Previous retry attempts..."
      )

      # CheckStaleReportsJob marks as failed (no more retries)
      expect {
        CheckStaleReportsJob.new.perform
      }.to change { report.reload.status }.from("running").to("failed")

      expect(report.logs).to include("after #{CheckStaleReportsJob::MAX_INTERRUPT_RETRIES} retry attempts")
    end
  end

  describe "Scenario 5: Target becomes unhealthy during retry window" do
    it "skips retry when target status is bad" do
      # Simulate: Report interrupted, but target validation failed since then
      report = create(:report,
        target: bad_target, # Target is now "bad"
        scan: scan,
        status: :interrupted,
        retry_count: 0,
        updated_at: 5.minutes.ago
      )

      # RetryInterruptedReportsJob skips due to bad target
      RetryInterruptedReportsJob.new.perform

      expect(report.reload.status).to eq("interrupted") # Unchanged
      expect(report.retry_count).to eq(0) # Not incremented
    end
  end

  describe "Scenario 6: Concurrent pod recovery (race condition)" do
    it "only one pod wins the atomic claim" do
      allow(SettingsService).to receive(:parallel_scans_limit).and_return(10)

      report = create(:report,
        target: target,
        scan: scan,
        status: :pending,
        retry_count: 1,
        last_retry_at: 10.minutes.ago
      )

      # Simulate two pods trying to claim simultaneously
      # Pod 1 claims successfully
      claim1_result = Report.where(id: report.id, status: :pending)
                            .update_all(status: :starting, updated_at: Time.current)

      # Pod 2 tries to claim the same report (should fail)
      claim2_result = Report.where(id: report.id, status: :pending)
                            .update_all(status: :starting, updated_at: Time.current)

      expect(claim1_result).to eq(1) # Success
      expect(claim2_result).to eq(0) # Failed - already claimed
      expect(report.reload.status).to eq("starting")
    end
  end

  describe "Scenario 7: Retry prioritization in queue" do
    it "processes retried reports before new reports" do
      allow(SettingsService).to receive(:parallel_scans_limit).and_return(1)

      # Old report, never retried
      new_report = create(:report,
        target: target,
        scan: scan,
        status: :pending,
        created_at: 1.day.ago,
        retry_count: 0,
        last_retry_at: nil
      )

      # Newer report, but has been retried (higher priority)
      retried_report = create(:report,
        target: target,
        scan: scan,
        status: :pending,
        created_at: 1.hour.ago,
        retry_count: 2,
        last_retry_at: 10.minutes.ago # Backoff elapsed
      )

      StartPendingScansJob.new.perform

      # Retried report should be started first
      expect(retried_report.reload.status).to eq("starting")
      expect(new_report.reload.status).to eq("pending")
    end
  end

  describe "Scenario 8: Exponential backoff timing" do
    it "respects exponential backoff schedule" do
      allow(SettingsService).to receive(:parallel_scans_limit).and_return(10)

      # retry_count=1 → 2^1 = 2 minute backoff
      report_in_backoff = create(:report,
        target: target,
        scan: scan,
        status: :pending,
        retry_count: 1,
        last_retry_at: 1.minute.ago # Only 1 min ago, need 2 min
      )

      # retry_count=2 → 2^2 = 4 minute backoff
      report_backoff_elapsed = create(:report,
        target: target,
        scan: scan,
        status: :pending,
        retry_count: 2,
        last_retry_at: 5.minutes.ago # 5 min ago, need 4 min ✓
      )

      StartPendingScansJob.new.perform

      expect(report_in_backoff.reload.status).to eq("pending") # Still waiting
      expect(report_backoff_elapsed.reload.status).to eq("starting") # Can proceed
    end
  end

  describe "Scenario 9: Multiple concurrent interruptions" do
    it "handles multiple reports interrupted simultaneously" do
      reports = 5.times.map do |i|
        create(:report,
          target: target,
          scan: scan,
          status: :running,
          pid: 12345 + i,
          heartbeat_at: (5 + i).minutes.ago,
          retry_count: 0
        )
      end

      # All should be marked interrupted
      CheckStaleReportsJob.new.perform

      reports.each do |report|
        expect(report.reload.status).to eq("interrupted")
      end

      # Simulate stabilization delay
      reports.each { |r| r.update_column(:updated_at, 1.minute.ago) }

      # All should be retried
      RetryInterruptedReportsJob.new.perform

      reports.each do |report|
        report.reload
        expect(report.status).to eq("pending")
        expect(report.retry_count).to eq(1)
      end
    end
  end

  describe "Scenario 10: Log preservation across retries" do
    it "preserves full log history through retry cycles" do
      report = create(:report,
        target: target,
        scan: scan,
        status: :running,
        pid: 12345,
        heartbeat_at: 5.minutes.ago,
        retry_count: 0,
        logs: "[2025-01-01 10:00:00] Original scan log"
      )

      # First interruption
      CheckStaleReportsJob.new.perform
      report.reload
      expect(report.logs).to include("[2025-01-01 10:00:00] Original scan log")
      expect(report.logs).to include("Interrupted:")

      # First retry
      report.update_column(:updated_at, 1.minute.ago)
      RetryInterruptedReportsJob.new.perform
      report.reload
      expect(report.logs).to include("Auto-retry 1:")

      # Simulate second run and interruption
      report.update!(status: :running, pid: 12346, heartbeat_at: 5.minutes.ago)
      CheckStaleReportsJob.new.perform
      report.reload

      # All logs should be preserved
      expect(report.logs).to include("[2025-01-01 10:00:00] Original scan log")
      expect(report.logs).to include("Auto-retry 1:")
      expect(report.logs.scan(/Interrupted:/).count).to eq(2) # Two interruptions logged
    end
  end

  describe "Scenario 11: Orphaned running process (PID cleared without status update)" do
    it "recovers a scan whose PID was cleared but status remained running" do
      # Simulate: The parent process called notify_report_stopped (PID matched, so
      # PID was cleared), but the process was killed before a terminal status was
      # set. The report is left running with no owning process.
      report = create(:report,
        target: target,
        scan: scan,
        status: :running,
        pid: nil,
        heartbeat_at: 1.minute.ago,
        updated_at: 3.minutes.ago,
        retry_count: 0,
        logs: "[2025-01-01 10:00:00] Scan started\n[2025-01-01 10:01:00] Heartbeat sent"
      )

      initial_logs = report.logs

      # Step 1: CheckStaleReportsJob detects the orphaned report
      expect {
        CheckStaleReportsJob.new.perform
      }.to change { report.reload.status }.from("running").to("interrupted")

      # Verify orphan-specific interruption message
      expect(report.logs).to include(initial_logs)
      expect(report.logs).to include("Interrupted:")
      expect(report.logs).to include("orphaned")
      expect(report.logs).to include("pid cleared but status not updated")

      # Step 2: Stabilization delay prevents immediate retry
      RetryInterruptedReportsJob.new.perform
      expect(report.reload.status).to eq("interrupted")

      # Step 3: After stabilization delay, retry moves to pending
      report.update_column(:updated_at, 35.seconds.ago)

      expect {
        RetryInterruptedReportsJob.new.perform
      }.to change { report.reload.status }.from("interrupted").to("pending")

      expect(report.retry_count).to eq(1)
      expect(report.heartbeat_at).to be_nil
      expect(report.pid).to be_nil
      expect(report.logs).to include("Auto-retry 1:")
      expect(report.logs).to include("Requeued after interruption")

      # Step 4: StartPendingScansJob picks it up
      report.update_column(:last_retry_at, 3.minutes.ago)
      allow(SettingsService).to receive(:parallel_scans_limit).and_return(5)

      expect {
        StartPendingScansJob.new.perform
      }.to change { report.reload.status }.from("pending").to("starting")
    end
  end

  describe "Scenario 12: Orphaned running with exhausted retries" do
    it "fails permanently when orphaned and retries exhausted" do
      report = create(:report,
        target: target,
        scan: scan,
        status: :running,
        pid: nil,
        heartbeat_at: 1.minute.ago,
        updated_at: 3.minutes.ago,
        retry_count: CheckStaleReportsJob::MAX_INTERRUPT_RETRIES,
        logs: "Multiple retry attempts exhausted..."
      )

      expect {
        CheckStaleReportsJob.new.perform
      }.to change { report.reload.status }.from("running").to("failed")

      expect(report.logs).to include("orphaned")
      expect(report.logs).to include("after #{CheckStaleReportsJob::MAX_INTERRUPT_RETRIES} retry attempts")
    end
  end

  describe "Job scheduling verification" do
    it "has correct recurring job configuration" do
      config_path = Rails.root.join("config/recurring.yml")
      config = YAML.load_file(config_path, aliases: true)

      # Verify retry job is scheduled
      retry_job = config.dig("common_jobs", "retry_interrupted_reports_job")
      expect(retry_job).to be_present
      expect(retry_job["class"]).to eq("RetryInterruptedReportsJob")
      expect(retry_job["schedule"]).to eq("every 30 seconds")

      # Verify check stale job is scheduled
      check_job = config.dig("common_jobs", "check_stale_reports_job")
      expect(check_job).to be_present
      expect(check_job["class"]).to eq("CheckStaleReportsJob")
      expect(check_job["schedule"]).to eq("every minute")

      # Verify start pending job is scheduled
      start_job = config.dig("common_jobs", "start_pending_scans_job")
      expect(start_job).to be_present
      expect(start_job["class"]).to eq("StartPendingScansJob")
      expect(start_job["schedule"]).to eq("every minute")
    end
  end

  describe "Constants verification" do
    it "has correct timeout and retry constants" do
      expect(CheckStaleReportsJob::HEARTBEAT_TIMEOUT).to eq(2.minutes)
      expect(CheckStaleReportsJob::STARTING_TIMEOUT).to eq(2.minutes)
      expect(CheckStaleReportsJob::MAX_START_RETRIES).to eq(3)
      expect(CheckStaleReportsJob::MAX_INTERRUPT_RETRIES).to eq(3)
      expect(RetryInterruptedReportsJob::STABILIZATION_DELAY).to eq(30.seconds)
    end
  end

  describe "Report status enum" do
    it "includes interrupted status with correct value" do
      expect(Report.statuses).to include("interrupted" => 7)
    end

    it "provides interrupted? predicate method" do
      report = build(:report, status: :interrupted)
      expect(report.interrupted?).to be true
      expect(report.running?).to be false
    end

    it "provides interrupted scope" do
      interrupted = create(:report, target: target, scan: scan, status: :interrupted)
      running = create(:report, target: target, scan: scan, status: :running, heartbeat_at: Time.current)

      expect(Report.interrupted).to include(interrupted)
      expect(Report.interrupted).not_to include(running)
    end
  end
end
