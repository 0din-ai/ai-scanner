# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Interrupted Reports Lifecycle", type: :integration do
  let(:target) { create(:target, :good) }
  let(:bad_target) { create(:target, :bad) }
  let(:scan) { create(:complete_scan) }

  before do
    allow_any_instance_of(ToastNotifier).to receive(:call)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    allow_any_instance_of(RunGarakScan).to receive(:call)
    # Stub the Solid Queue lookup - in test env we don't have Solid Queue tables
    allow_any_instance_of(CheckStaleReportsJob).to receive(:pending_process_job_report_ids).and_return(Set.new)
  end

  describe "complete lifecycle: running -> interrupted -> pending -> starting" do
    it "processes through the full recovery cycle" do
      # Step 1: Create running report with stale heartbeat
      report = create(:report,
        target: target,
        scan: scan,
        status: :running,
        pid: 12345,
        heartbeat_at: 5.minutes.ago,
        retry_count: 0,
        logs: "Initial log"
      )
      expect(report.status).to eq("running")

      # Step 2: CheckStaleReportsJob marks it as interrupted
      CheckStaleReportsJob.new.perform
      report.reload

      expect(report.status).to eq("interrupted")
      expect(report.logs).to include("Interrupted")
      expect(report.logs).to include("Scan stopped responding")

      # Step 3: RetryInterruptedReportsJob within stabilization delay - no change
      RetryInterruptedReportsJob.new.perform
      report.reload

      expect(report.status).to eq("interrupted") # Should still be interrupted

      # Step 4: Simulate time passing past stabilization delay
      report.update_column(:updated_at, 1.minute.ago)

      # Step 5: RetryInterruptedReportsJob after delay - moves to pending
      RetryInterruptedReportsJob.new.perform
      report.reload

      expect(report.status).to eq("pending")
      expect(report.retry_count).to eq(1)
      expect(report.heartbeat_at).to be_nil # Reset for fresh start
      expect(report.logs).to include("Auto-retry 1")
      expect(report.logs).to include("Requeued after interruption")
    end
  end

  describe "retry prioritization" do
    it "prioritizes retried reports over new reports" do
      allow(SettingsService).to receive(:parallel_scans_limit).and_return(1)

      # Create an older new report
      new_report = create(:report,
        target: target,
        scan: scan,
        status: :pending,
        created_at: 2.hours.ago,
        retry_count: 0,
        last_retry_at: nil
      )

      # Create a newer retried report (backoff elapsed)
      retried_report = create(:report,
        target: target,
        scan: scan,
        status: :pending,
        created_at: 1.hour.ago,
        retry_count: 1,
        last_retry_at: 5.minutes.ago
      )

      StartPendingScansJob.new.perform

      new_report.reload
      retried_report.reload

      # Retried report should start first despite being newer
      expect(retried_report.status).to eq("starting")
      expect(new_report.status).to eq("pending")
    end
  end

  describe "max retries enforcement" do
    it "fails report after max retries" do
      # Create report at max retries
      report = create(:report,
        target: target,
        scan: scan,
        status: :running,
        pid: 12345,
        heartbeat_at: 5.minutes.ago,
        retry_count: 3, # MAX_INTERRUPT_RETRIES
        logs: "Previous logs"
      )

      CheckStaleReportsJob.new.perform
      report.reload

      expect(report.status).to eq("failed")
      expect(report.logs).to include("after 3 retry attempts")
    end

    it "interrupts report under max retries" do
      report = create(:report,
        target: target,
        scan: scan,
        status: :running,
        pid: 12345,
        heartbeat_at: 5.minutes.ago,
        retry_count: 2, # Under max
        logs: "Previous logs"
      )

      CheckStaleReportsJob.new.perform
      report.reload

      expect(report.status).to eq("interrupted")
    end
  end

  describe "target status enforcement" do
    it "skips retry for bad target status" do
      report = create(:report,
        target: bad_target,
        scan: scan,
        status: :interrupted,
        retry_count: 0,
        updated_at: 5.minutes.ago
      )

      RetryInterruptedReportsJob.new.perform
      report.reload

      expect(report.status).to eq("interrupted") # Should not change
      expect(report.retry_count).to eq(0)
    end

    it "retries for good target status" do
      report = create(:report,
        target: target,
        scan: scan,
        status: :interrupted,
        retry_count: 0,
        updated_at: 5.minutes.ago
      )

      RetryInterruptedReportsJob.new.perform
      report.reload

      expect(report.status).to eq("pending")
      expect(report.retry_count).to eq(1)
    end
  end

  describe "exponential backoff integration" do
    it "respects backoff when starting pending reports" do
      allow(SettingsService).to receive(:parallel_scans_limit).and_return(10)

      # Report still in backoff (retry_count=2 means 4 min backoff)
      in_backoff = create(:report,
        target: target,
        scan: scan,
        status: :pending,
        retry_count: 2,
        last_retry_at: 2.minutes.ago
      )

      # Report with backoff elapsed
      backoff_elapsed = create(:report,
        target: target,
        scan: scan,
        status: :pending,
        retry_count: 2,
        last_retry_at: 10.minutes.ago
      )

      StartPendingScansJob.new.perform

      in_backoff.reload
      backoff_elapsed.reload

      expect(in_backoff.status).to eq("pending") # Still waiting
      expect(backoff_elapsed.status).to eq("starting") # Can proceed
    end
  end

  describe "never-started reports handling" do
    it "marks never-started reports as interrupted" do
      # Report in running state but never received heartbeat
      report = create(:report,
        target: target,
        scan: scan,
        status: :running,
        heartbeat_at: nil,
        updated_at: 5.minutes.ago,
        retry_count: 0
      )

      CheckStaleReportsJob.new.perform
      report.reload

      expect(report.status).to eq("interrupted")
      expect(report.logs).to include("Scan process never started")
    end
  end

  describe "stuck starting reports handling" do
    it "requeues stuck starting reports" do
      report = create(:report,
        target: target,
        scan: scan,
        status: :starting,
        retry_count: 0,
        updated_at: 5.minutes.ago
      )

      CheckStaleReportsJob.new.perform
      report.reload

      expect(report.status).to eq("pending")
      expect(report.retry_count).to eq(1)
      expect(report.logs).to include("Retry 1")
      expect(report.logs).to include("timed out")
    end
  end

  describe "orphaned running reports recovery" do
    it "recovers orphaned report through full lifecycle: running(orphaned) -> interrupted -> pending" do
      # Simulate: Parent called notify_report_stopped (PID matched, so pid was cleared),
      # but the process was killed before a terminal status was set.
      report = create(:report,
        target: target,
        scan: scan,
        status: :running,
        pid: nil,
        heartbeat_at: 1.minute.ago,
        updated_at: 3.minutes.ago,
        retry_count: 0,
        logs: "Initial scan log"
      )
      expect(report.status).to eq("running")
      expect(report.pid).to be_nil

      # Step 1: CheckStaleReportsJob detects orphaned report
      CheckStaleReportsJob.new.perform
      report.reload

      expect(report.status).to eq("interrupted")
      expect(report.logs).to include("Interrupted")
      expect(report.logs).to include("orphaned")

      # Step 2: Immediately after, retry job respects stabilization delay
      RetryInterruptedReportsJob.new.perform
      report.reload
      expect(report.status).to eq("interrupted")

      # Step 3: After stabilization delay, retry moves to pending
      report.update_column(:updated_at, 1.minute.ago)

      RetryInterruptedReportsJob.new.perform
      report.reload

      expect(report.status).to eq("pending")
      expect(report.retry_count).to eq(1)
      expect(report.heartbeat_at).to be_nil
      expect(report.pid).to be_nil
      expect(report.logs).to include("Auto-retry 1")
      expect(report.logs).to include("Requeued after interruption")
    end

    it "fails orphaned report after max retries" do
      report = create(:report,
        target: target,
        scan: scan,
        status: :running,
        pid: nil,
        heartbeat_at: 1.minute.ago,
        updated_at: 3.minutes.ago,
        retry_count: 3,
        logs: "Previous retries exhausted"
      )

      CheckStaleReportsJob.new.perform
      report.reload

      expect(report.status).to eq("failed")
      expect(report.logs).to include("after 3 retry attempts")
    end

    it "does not treat running report with active pid as orphaned" do
      report = create(:report,
        target: target,
        scan: scan,
        status: :running,
        pid: 12345,
        heartbeat_at: 30.seconds.ago,
        updated_at: 3.minutes.ago,
        retry_count: 0
      )

      CheckStaleReportsJob.new.perform
      report.reload

      # pid is present and heartbeat is recent, so report is healthy
      expect(report.status).to eq("running")
    end
  end

  describe "pid cleared on retry" do
    it "clears stale pid when retrying interrupted report" do
      report = create(:report,
        target: target,
        scan: scan,
        status: :interrupted,
        pid: 99999,
        heartbeat_at: 5.minutes.ago,
        retry_count: 0,
        updated_at: 5.minutes.ago
      )

      RetryInterruptedReportsJob.new.perform
      report.reload

      expect(report.status).to eq("pending")
      expect(report.pid).to be_nil
      expect(report.heartbeat_at).to be_nil
    end
  end

  describe "concurrent processing safety" do
    it "handles atomic claiming for starting reports" do
      allow(SettingsService).to receive(:parallel_scans_limit).and_return(5)

      report = create(:report,
        target: target,
        scan: scan,
        status: :pending
      )

      # Simulate two concurrent claim attempts
      # First claim succeeds
      result1 = Report.where(id: report.id, status: :pending)
                      .update_all(status: :starting, updated_at: Time.current)

      # Second claim fails (status already changed)
      result2 = Report.where(id: report.id, status: :pending)
                      .update_all(status: :starting, updated_at: Time.current)

      expect(result1).to eq(1) # One row updated
      expect(result2).to eq(0) # Zero rows updated
    end
  end
end
