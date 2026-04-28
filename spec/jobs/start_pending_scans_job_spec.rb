# frozen_string_literal: true

require "rails_helper"

RSpec.describe StartPendingScansJob, type: :job do
  let(:target) { create(:target, status: "good") }
  let(:scan) { create(:complete_scan) }

  before do
    allow_any_instance_of(ToastNotifier).to receive(:call)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    # Prevent actual scan execution
    allow_any_instance_of(RunGarakScan).to receive(:call)
    # Force scan creation, then clean up auto-created reports
    scan
    Report.delete_all
  end

  describe "#perform" do
    describe "available slots calculation" do
      before do
        allow(SettingsService).to receive(:parallel_scans_limit).and_return(5)
      end

      it "starts pending scans when slots available" do
        report = create(:report, target: target, scan: scan, status: :pending)

        expect_any_instance_of(RunGarakScan).to receive(:call)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("starting")
      end

      it "does nothing when no slots available" do
        # Create 5 running reports to fill all slots
        5.times do
          create(:report, target: target, scan: scan, status: :running, heartbeat_at: Time.current)
        end
        pending_report = create(:report, target: target, scan: scan, status: :pending)

        expect_any_instance_of(RunGarakScan).not_to receive(:call)

        described_class.new.perform

        expect(pending_report.reload.status).to eq("pending")
      end

      it "respects parallel_scans_limit setting" do
        # Create 2 running reports to use up slots
        2.times do
          create(:report, target: target, scan: scan, status: :running, heartbeat_at: Time.current)
        end

        # With limit=5 and 2 running, we have 3 available slots
        # Create 5 pending reports - only 3 should start
        reports = 5.times.map do
          create(:report, target: target, scan: scan, status: :pending)
        end

        described_class.new.perform

        started_count = reports.map(&:reload).count { |r| r.status == "starting" }
        pending_count = reports.map(&:reload).count { |r| r.status == "pending" }

        expect(started_count).to eq(3)
        expect(pending_count).to eq(2)
      end

      it "counts active reports (starting + running only, not processing)" do
        allow(SettingsService).to receive(:parallel_scans_limit).and_return(3)

        # Only starting and running count as "active" (using garak process slots)
        # Processing reports don't have a garak process running
        create(:report, target: target, scan: scan, status: :starting)
        create(:report, target: target, scan: scan, status: :running, heartbeat_at: Time.current)
        create(:report, target: target, scan: scan, status: :running, heartbeat_at: Time.current)

        pending_report = create(:report, target: target, scan: scan, status: :pending)

        expect_any_instance_of(RunGarakScan).not_to receive(:call)

        described_class.new.perform

        expect(pending_report.reload.status).to eq("pending")
      end
    end

    describe "exponential backoff" do
      before do
        allow(SettingsService).to receive(:parallel_scans_limit).and_return(10)
      end

      it "starts reports with no previous retries (last_retry_at is nil)" do
        report = create(:report, target: target, scan: scan, status: :pending, last_retry_at: nil, retry_count: 0)

        described_class.new.perform

        expect(report.reload.status).to eq("starting")
      end

      it "skips reports still in backoff period (retry_count=1, 2 min backoff)" do
        # retry_count=1 means 2^1 = 2 minutes backoff
        # Set last_retry_at to 1 minute ago - still in backoff
        report = create(:report, target: target, scan: scan, status: :pending,
                        last_retry_at: 1.minute.ago, retry_count: 1)

        expect_any_instance_of(RunGarakScan).not_to receive(:call)

        described_class.new.perform

        expect(report.reload.status).to eq("pending")
      end

      it "starts reports after backoff period elapsed (retry_count=1, 2 min backoff)" do
        # retry_count=1 means 2^1 = 2 minutes backoff
        # Set last_retry_at to 3 minutes ago - backoff elapsed
        report = create(:report, target: target, scan: scan, status: :pending,
                        last_retry_at: 3.minutes.ago, retry_count: 1)

        described_class.new.perform

        expect(report.reload.status).to eq("starting")
      end

      it "handles retry_count=2 with 4 minute backoff" do
        # retry_count=2 means 2^2 = 4 minutes backoff
        still_in_backoff = create(:report, target: target, scan: scan, status: :pending,
                                  last_retry_at: 3.minutes.ago, retry_count: 2)
        backoff_elapsed = create(:report, target: target, scan: scan, status: :pending,
                                 last_retry_at: 5.minutes.ago, retry_count: 2)

        described_class.new.perform

        expect(still_in_backoff.reload.status).to eq("pending")
        expect(backoff_elapsed.reload.status).to eq("starting")
      end

      it "handles retry_count=3 with 8 minute backoff" do
        # retry_count=3 means 2^3 = 8 minutes backoff
        still_in_backoff = create(:report, target: target, scan: scan, status: :pending,
                                  last_retry_at: 7.minutes.ago, retry_count: 3)
        backoff_elapsed = create(:report, target: target, scan: scan, status: :pending,
                                 last_retry_at: 9.minutes.ago, retry_count: 3)

        described_class.new.perform

        expect(still_in_backoff.reload.status).to eq("pending")
        expect(backoff_elapsed.reload.status).to eq("starting")
      end
    end

    describe "atomic claiming" do
      before do
        allow(SettingsService).to receive(:parallel_scans_limit).and_return(5)
      end

      it "claims report atomically by updating status to starting" do
        report = create(:report, target: target, scan: scan, status: :pending)

        described_class.new.perform

        report.reload
        expect(report.status).to eq("starting")
      end

      it "clears stale live tail when claiming a retry for starting" do
        report = create(:report, target: target, scan: scan, status: :pending, retry_count: 1)
        debug_log = create(:report_debug_log, report: report, tail: "previous attempt tail\n", tail_offset: 128, tail_digest: "old-tail", tail_synced_at: 1.minute.ago, tail_truncated: true)

        described_class.new.perform

        debug_log.reload
        expect(report.reload.status).to eq("starting")
        expect(debug_log.tail).to be_nil
        expect(debug_log.tail_offset).to eq(0)
        expect(debug_log.tail_digest).to be_nil
        expect(debug_log.tail_synced_at).to be_nil
        expect(debug_log.tail_truncated).to be(false)
      end

      it "does not start scan if claim fails (status changed)" do
        report = create(:report, target: target, scan: scan, status: :pending)

        # Simulate another process claiming the report first
        allow(Report).to receive(:where).and_call_original
        allow(Report).to receive(:where).with(id: report.id, status: :pending).and_return(
          double(update_all: 0) # Simulate failed claim (0 rows updated)
        )

        # RunGarakScan should NOT be called since claim failed
        expect_any_instance_of(RunGarakScan).not_to receive(:call)

        described_class.new.perform
      end

      it "reloads report after successful claim before calling RunGarakScan" do
        report = create(:report, target: target, scan: scan, status: :pending)

        run_garak_double = instance_double(RunGarakScan)
        allow(run_garak_double).to receive(:call)

        # Verify RunGarakScan receives reloaded report
        expect(RunGarakScan).to receive(:new) do |r|
          expect(r.id).to eq(report.id)
          expect(r.status).to eq("starting")
          run_garak_double
        end

        described_class.new.perform
      end
    end

    describe "target status" do
      before do
        allow(SettingsService).to receive(:parallel_scans_limit).and_return(5)
      end

      it "starts scan for targets with good status" do
        good_target = create(:target, status: "good")
        report = create(:report, target: good_target, scan: scan, status: :pending)

        expect_any_instance_of(RunGarakScan).to receive(:call)

        described_class.new.perform

        expect(report.reload.status).to eq("starting")
      end

      it "marks report as failed for targets with bad status" do
        bad_target = create(:target, status: "bad", validation_text: "Connection refused")
        bad_scan = create(:complete_scan, company: bad_target.company)
        report = create(:report, target: bad_target, scan: bad_scan, status: :pending, company: bad_target.company)

        # Override global stub to handle invalid target status
        allow_any_instance_of(RunGarakScan).to receive(:call) do |scan_service|
          t = scan_service.report.target
          unless t&.status == "good"
            scan_service.send(:handle_invalid_target_status)
          end
        end

        described_class.new.perform

        report.reload
        expect(report.status).to eq("failed")
        expect(report.logs).to include("Target '#{bad_target.name}' validation failed")
      end

      it "marks report as failed for targets with validating status" do
        validating_target = create(:target, status: "validating")
        validating_scan = create(:complete_scan, company: validating_target.company)
        report = create(:report, target: validating_target, scan: validating_scan, status: :pending, company: validating_target.company)

        # Override global stub to handle invalid target status
        allow_any_instance_of(RunGarakScan).to receive(:call) do |scan_service|
          t = scan_service.report.target
          unless t&.status == "good"
            scan_service.send(:handle_invalid_target_status)
          end
        end

        described_class.new.perform

        report.reload
        expect(report.status).to eq("failed")
        expect(report.logs).to include("still being validated")
      end
    end

    describe "ordering and limits" do
      before do
        allow(SettingsService).to receive(:parallel_scans_limit).and_return(5)
      end

      it "starts reports in created_at order when retry_count is equal" do
        # Create reports with specific timestamps and same retry_count
        newer_report = create(:report, target: target, scan: scan, status: :pending, created_at: 1.hour.ago, retry_count: 0)
        older_report = create(:report, target: target, scan: scan, status: :pending, created_at: 2.hours.ago, retry_count: 0)

        # Only allow 1 slot
        allow(SettingsService).to receive(:parallel_scans_limit).and_return(1)

        described_class.new.perform

        expect(older_report.reload.status).to eq("starting")
        expect(newer_report.reload.status).to eq("pending")
      end

      it "prioritizes retried reports over new reports" do
        # Create an older new report and a newer retried report
        new_report = create(:report, target: target, scan: scan, status: :pending, created_at: 2.hours.ago, retry_count: 0)
        retried_report = create(:report, target: target, scan: scan, status: :pending, created_at: 1.hour.ago, retry_count: 1, last_retry_at: 5.minutes.ago)

        # Only allow 1 slot
        allow(SettingsService).to receive(:parallel_scans_limit).and_return(1)

        described_class.new.perform

        # Retried report should be started first despite being newer
        expect(retried_report.reload.status).to eq("starting")
        expect(new_report.reload.status).to eq("pending")
      end
    end

    describe "priority scans" do
      # Create priority scan without auto-creating reports by clearing them after creation
      let(:priority_scan) do
        scan = create(:complete_scan, priority: true)
        scan.reports.delete_all  # Remove auto-created reports
        scan
      end

      it "starts priority scans even when slots are full" do
        # Set limit to 0 to simulate full slots
        allow(SettingsService).to receive(:parallel_scans_limit).and_return(0)

        priority_report = create(:report, target: target, scan: priority_scan, status: :pending)
        standard_report = create(:report, target: target, scan: scan, status: :pending)

        expect_any_instance_of(RunGarakScan).to receive(:call)

        described_class.new.perform

        expect(priority_report.reload.status).to eq("starting")
        expect(standard_report.reload.status).to eq("pending")
      end

      it "starts multiple priority scans" do
        allow(SettingsService).to receive(:parallel_scans_limit).and_return(0)

        reports = 3.times.map do
          create(:report, target: target, scan: priority_scan, status: :pending)
        end

        # Use a spy to verify calls instead of expect_any_instance_of
        run_scan_spy = instance_double(RunGarakScan)
        allow(RunGarakScan).to receive(:new).and_return(run_scan_spy)
        expect(run_scan_spy).to receive(:call).exactly(3).times

        described_class.new.perform

        expect(reports.map(&:reload).all? { |r| r.status == "starting" }).to be true
      end
    end

    describe "multiple pending reports" do
      before do
        allow(SettingsService).to receive(:parallel_scans_limit).and_return(10)
      end

      it "processes multiple eligible pending reports" do
        reports = 3.times.map do
          create(:report, target: target, scan: scan, status: :pending)
        end

        described_class.new.perform

        started_reports = reports.map(&:reload).select { |r| r.status == "starting" }
        expect(started_reports.count).to eq(3)
      end

      it "handles mix of eligible and ineligible reports" do
        eligible = create(:report, target: target, scan: scan, status: :pending, last_retry_at: nil)
        in_backoff = create(:report, target: target, scan: scan, status: :pending,
                            last_retry_at: 30.seconds.ago, retry_count: 1)
        bad_target = create(:target, status: "bad")
        bad_scan = create(:complete_scan, company: bad_target.company)
        bad_target_report = create(:report, target: bad_target, scan: bad_scan, status: :pending, company: bad_target.company)

        # Override global stub to handle invalid target status (nil-safe for company-mismatched reports)
        allow_any_instance_of(RunGarakScan).to receive(:call) do |scan_service|
          t = scan_service.report.target
          if t && t.status != "good"
            scan_service.send(:handle_invalid_target_status)
          end
        end

        described_class.new.perform

        expect(eligible.reload.status).to eq("starting")
        expect(in_backoff.reload.status).to eq("pending")
        # Reports for bad targets are now properly marked as failed
        expect(bad_target_report.reload.status).to eq("failed")
      end
    end
  end

  describe "queue configuration" do
    it "uses default queue" do
      expect(described_class.new.queue_name).to eq("default")
    end
  end

  describe "tenant context for RunGarakScan" do
    before do
      allow(SettingsService).to receive(:parallel_scans_limit).and_return(5)
    end

    it "sets tenant context before calling RunGarakScan" do
      report = create(:report, target: target, scan: scan, status: :pending)
      tenant_during_call = nil

      allow_any_instance_of(RunGarakScan).to receive(:call) do |service|
        tenant_during_call = ActsAsTenant.current_tenant
      end

      described_class.new.perform

      expect(tenant_during_call).to eq(report.company)
    end
  end
end
