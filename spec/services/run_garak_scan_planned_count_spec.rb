# frozen_string_literal: true

require "rails_helper"

# planned_probe_count is what lets anything downstream tell a run that finished its
# whole plan from one that stopped partway. It was recorded inside the execution claim,
# which the normal path never reaches -- StartPendingScansJob has already moved the
# report to `starting`, so start_execution_attempt! returned immediately.
#
# The effect was that ordinary runs left the column NULL and every one of them read as
# complete, whatever fraction of its probes actually ran.
RSpec.describe RunGarakScan, "planned probe count" do
  let(:company) { create(:company) }
  let(:probes) { create_list(:probe, 3) }
  let(:target) { ActsAsTenant.with_tenant(company) { create(:target, company: company) } }
  let(:scan) do
    ActsAsTenant.with_tenant(company) do
      create(:scan, company: company, probes: probes, targets: [ target ])
    end
  end
  let(:report) do
    ActsAsTenant.with_tenant(company) { create(:report, company: company, scan: scan, target: target, status: status) }
  end

  subject(:service) { described_class.new(report) }

  context "on the normal path, where the scheduler already claimed the report" do
    let(:status) { :starting }

    it "records the plan even though the claim is a no-op" do
      ActsAsTenant.with_tenant(company) { service.send(:start_execution_attempt!) }

      expect(report.reload.planned_probe_count).to eq(3)
    end
  end

  context "on a path that still has to claim the report" do
    let(:status) { :pending }

    it "still records the plan" do
      ActsAsTenant.with_tenant(company) { service.send(:start_execution_attempt!) }

      expect(report.reload.planned_probe_count).to eq(3)
    end
  end

  describe "what the recorded plan changes" do
    let(:status) { :starting }

    it "lets a short run be classified as partial instead of complete" do
      # This is the point of the fix, and it is a behaviour change: with the column
      # NULL, compute_derived_result_completeness returns "complete" for every
      # completed report because it has no plan to compare against.
      ActsAsTenant.with_tenant(company) do
        service.send(:start_execution_attempt!)
        report.reload
        allow(report).to receive(:processed_scope).and_return(1)
        report.status = :completed

        expect(report.send(:compute_derived_result_completeness)).to eq("partial")
      end
    end

    it "still calls a full run complete" do
      ActsAsTenant.with_tenant(company) do
        service.send(:start_execution_attempt!)
        report.reload
        allow(report).to receive(:processed_scope).and_return(3)
        report.status = :completed

        expect(report.send(:compute_derived_result_completeness)).to eq("complete")
      end
    end
  end

  describe "ownership" do
    let(:status) { :pending }

    it "does not record a plan for an attempt that loses the claim" do
      # A loser's plan is derived from the probe list AS IT SAW IT, and
      # Scanner.run_hooks(:before_scan_start) can still change what the winner runs. A
      # stale higher plan survives "never lower" and marks the winner's complete run
      # partial -- so only the owner of an attempt may record one.
      ActsAsTenant.with_tenant(company) do
        # Someone else claims it between our status read and our conditional UPDATE.
        Report.unscoped.where(id: report.id).update_all(status: Report.statuses[:starting])

        service.send(:start_execution_attempt!)
      end

      expect(report.reload.planned_probe_count).to be_nil
    end
  end

  describe "concurrent recording" do
    let(:status) { :starting }

    it "cannot be lowered by a write that lands last" do
      # Read-then-write let two attempts both read the old value and let the SMALLER
      # write land last. The conditional UPDATE makes the raise monotonic in the
      # database rather than in Ruby.
      ActsAsTenant.with_tenant(company) do
        report.update_columns(planned_probe_count: 9)
        allow(report).to receive(:planned_probe_count_for_run).and_return(2)

        service.send(:record_planned_probe_count!)
      end

      expect(report.reload.planned_probe_count).to eq(9)
    end
  end

  describe "the recorder's existing guarantees, now on the normal path too" do
    let(:status) { :starting }

    it "never lowers a plan the report already exceeded" do
      # A scan edited down must not shrink a plan this report already ran past.
      ActsAsTenant.with_tenant(company) do
        report.update_columns(planned_probe_count: 7)
        service.send(:start_execution_attempt!)
      end

      expect(report.reload.planned_probe_count).to eq(7)
    end

    it "raises a plan that grew between attempts" do
      ActsAsTenant.with_tenant(company) do
        report.update_columns(planned_probe_count: 1)
        service.send(:start_execution_attempt!)
      end

      expect(report.reload.planned_probe_count).to eq(3)
    end
  end
end
