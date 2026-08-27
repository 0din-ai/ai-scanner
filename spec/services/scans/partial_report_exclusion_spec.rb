# frozen_string_literal: true

require "rails_helper"

# Recording a probe plan on the normal launch path makes ordinary short runs classify
# as partial for the first time. Every surface that MEASURES has to agree about that,
# or the scan page and the report page contradict each other: the report says partial
# while the scan's grade and ASR chart still average it in.
RSpec.describe "partial reports and measured figures" do
  let(:company) { create(:company) }
  let(:target) { ActsAsTenant.with_tenant(company) { create(:target, company: company) } }
  let(:scan) do
    ActsAsTenant.with_tenant(company) do
      create(:scan, company: company, targets: [ target ], probes: create_list(:probe, 2))
    end
  end

  def completed_report(completeness:, passed:, total:)
    ActsAsTenant.with_tenant(company) do
      report = create(:report, :completed, company: company, scan: scan, target: target)
      report.update_columns(result_completeness: completeness)
      create(:probe_result, report: report, passed: passed, total: total,
             input_tokens: total * 10, output_tokens: total * 20)
      report
    end
  end

  before do
    completed_report(completeness: "complete", passed: 1, total: 10)
    completed_report(completeness: "partial", passed: 5, total: 5)
  end

  def stats
    ActsAsTenant.with_tenant(company) { Scans::StatsSerializer.new(scan.reload).call }
  end

  # Formula-agnostic: whether the partial run is counted is shown by whether reclassifying
  # it changes the answer, not by predicting what the weighted score should be.
  it "keeps a partial run out of the customer-facing security grade" do
    with_partial = stats[:security_grade]

    ActsAsTenant.with_tenant(company) do
      Report.unscoped.where(result_completeness: "partial").update_all(result_completeness: "complete")
    end

    expect(stats[:security_grade]).not_to eq(with_partial)
  end

  it "keeps a partial run out of the ASR history chart" do
    # The chart plots one point per past run. A partial run's ASR reflects how much of
    # the plan executed, so plotting it shows a movement the target did not cause -- and
    # the report page already marks that run partial, so the two would contradict.
    plotted = ActsAsTenant.with_tenant(company) do
      Scans::HistoryEligibility.apply(Report.where(scan_id: scan.id)).count
    end

    expect(plotted).to eq(1)
  end

  it "keeps a partial run out of the token averages a projection is built on" do
    with_partial = ActsAsTenant.with_tenant(company) { scan.reload.actual_token_averages }

    ActsAsTenant.with_tenant(company) do
      Report.unscoped.where(result_completeness: "partial").update_all(result_completeness: "complete")
    end

    expect(ActsAsTenant.with_tenant(company) { scan.reload.actual_token_averages }).not_to eq(with_partial)
  end

  it "reports when the last run finished even if that run was partial" do
    # Lifecycle, not measurement: a scan whose only completed run was partial must not
    # report completed_reports: 1 beside last_report_at: nil.
    expect(stats[:stats][:last_report_at]).to be_present
  end

  it "still counts a partial run as a completed run" do
    # Lifecycle and measurement are different questions. The run did finish.
    stats = ActsAsTenant.with_tenant(company) { Scans::StatsSerializer.new(scan.reload).call }

    expect(stats[:stats][:completed_reports]).to eq(2)
  end
end
