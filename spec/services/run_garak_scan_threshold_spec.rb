# frozen_string_literal: true

require "rails_helper"

# Every segment of a report must be launched with the threshold the report is pinned
# to. Re-resolving live config at launch would let an edit land between two segments
# of one report, so a relaunch after an interruption would evaluate the rest of the
# run against a different cutoff than the part already done.
RSpec.describe RunGarakScan, "evaluation threshold argv" do
  let(:company) { create(:company) }
  let(:report) { ActsAsTenant.with_tenant(company) { create(:report, company: company) } }

  subject(:service) { described_class.new(report) }

  def threshold_flag
    service.send(:evaluation_threshold)
  end

  it "passes the report's pinned threshold" do
    ActsAsTenant.with_tenant(company) { report.update!(evaluation_threshold: 0.2) }

    expect(threshold_flag).to eq([ "--eval_threshold", "0.2" ])
  end

  it "ignores a live config change made after the report was pinned" do
    ActsAsTenant.with_tenant(company) do
      report.update!(evaluation_threshold: 0.2)
      EnvironmentVariable.create!(env_name: "EVALUATION_THRESHOLD", env_value: "0.9", company: company)
    end

    expect(threshold_flag).to eq([ "--eval_threshold", "0.2" ])
  end

  it "emits the flag even at the default, so garak's own default cannot drift from ours" do
    expect(threshold_flag).to eq([ "--eval_threshold", EnvironmentVariable::GARAK_DEFAULT_EVAL_THRESHOLD.to_s ])
  end

  it "resolves and persists a report that predates the snapshot column" do
    ActsAsTenant.with_tenant(company) do
      EnvironmentVariable.create!(env_name: "EVALUATION_THRESHOLD", env_value: "0.2", company: company)
    end
    Report.where(id: report.id).update_all(evaluation_threshold: nil)
    report.reload

    expect(threshold_flag).to eq([ "--eval_threshold", "0.2" ])
    # Persisted at launch, so processing cannot later resolve a different value.
    expect(Report.where(id: report.id).pick(:evaluation_threshold)).to eq(0.2)
  end
end

RSpec.describe GenerateVariantReportsJob, "evaluation threshold inheritance" do
  let(:company) { create(:company) }

  it "gives the child report its parent's threshold, not a fresh resolve" do
    probe = create(:probe, name: "ThresholdProbe")
    parent = ActsAsTenant.with_tenant(company) { create(:report, company: company, evaluation_threshold: 0.2) }
    ActsAsTenant.with_tenant(company) do
      EnvironmentVariable.create!(env_name: "EVALUATION_THRESHOLD", env_value: "0.9", company: company)
    end

    allow(VariantProbeMapper).to receive(:new).and_return(instance_double(VariantProbeMapper, call: [ probe ]))

    ActsAsTenant.with_tenant(company) do
      described_class.new.send(:create_combined_variant_report, parent, [ "0din.ThresholdProbe" ], [ 1 ])
    end

    # The child re-runs probes the parent selected under ITS threshold. Scoring the
    # pair at different cutoffs makes them incomparable.
    expect(parent.reload.child_report.evaluation_threshold).to eq(0.2)
  end
end
