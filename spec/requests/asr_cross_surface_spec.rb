# frozen_string_literal: true

require "rails_helper"

# The reports list, the overview and the customer report could disagree about the same
# report -- 83.24% / 83.2% / 83% for one rate, and "N/A" beside "0/3" counts while the
# overview said 0.0%. These fixtures cover the four report shapes that produced those
# disagreements and assert every surface tells the same story.
RSpec.describe "ASR consistency across report surfaces", type: :request do
  let(:company) { create(:company) }
  let(:user) { ActsAsTenant.with_tenant(company) { create(:user, :super_admin, company: company) } }
  let(:scan) { ActsAsTenant.with_tenant(company) { create(:complete_scan, company: company) } }
  let(:target) { ActsAsTenant.with_tenant(company) { create(:target, company: company) } }
  let(:probe) { ActsAsTenant.with_tenant(company) { create(:probe) } }
  let(:detector) { ActsAsTenant.with_tenant(company) { create(:detector) } }

  # The four production shapes this ticket was raised from.
  SHAPES = {
    "a completed scan with most attacks succeeding" => {
      status: :completed, completeness: :complete, passed: 8888, total: 10678,
      expected: "83.2%", headline: "83%"
    },
    "a completed scan that blocked every attack" => {
      status: :completed, completeness: :complete, passed: 0, total: 3,
      expected: "0.0%", headline: "0%"
    },
    "a failed scan that measured nothing" => {
      status: :failed, completeness: :none, passed: 0, total: 0,
      expected: "N/A", headline: "N/A"
    },
    "a failed scan holding partial results" => {
      status: :failed, completeness: :partial, passed: 5959, total: 7866,
      expected: "75.8%", headline: "76%"
    }
  }.freeze

  def build_report(status:, completeness:, passed:, total:)
    ActsAsTenant.with_tenant(company) do
      report = create(:report, company: company, scan: scan, target: target,
                               status: status, result_completeness: completeness)
      if total.positive?
        create(:probe_result, report: report, probe: probe, detector: detector,
                              passed: passed, total: total)
        create(:detector_result, report: report, detector: detector,
                                 passed: passed, total: total)
      end
      report
    end
  end

  before do
    user.update!(current_company: company)
    sign_in user
    ActsAsTenant.current_tenant = company
  end

  SHAPES.each do |description, shape|
    context "for #{description}" do
      let!(:report) { build_report(**shape.slice(:status, :completeness, :passed, :total)) }

      it "states the same rate on the reports list and the overview" do
        get reports_path
        expect(response.body).to include(shape[:expected])

        get report_path(report)
        expect(response.body).to include(shape[:expected])
      end

      it "derives the rate from one numerator and denominator" do
        figure = report.asr

        expect(figure.numerator).to eq(shape[:passed])
        expect(figure.denominator).to eq(shape[:total])
        expect(figure.calculable?).to eq(shape[:total].positive?)
      end

      it "never presents a measurable zero as unavailable" do
        get reports_path

        if shape[:total].positive?
          expect(response.body).to include(shape[:expected])
        else
          expect(response.body).to include("N/A")
        end
      end
    end
  end

  it "labels a partial rate as partial wherever it is shown" do
    report = build_report(status: :failed, completeness: :partial, passed: 5959, total: 7866)
    ActsAsTenant.with_tenant(company) do
      create(:detector_result, report: report, detector: create(:detector), passed: 1, total: 1)
      create(:probe_result, report: report, probe: create(:probe), detector: create(:detector), passed: 1, total: 1)
    end

    get report_detail_path(report)

    expect(response.body).to match(/partial/i)
  end

  it "plots the same rate the page states, rounded once" do
    # attack_success_rate is already rounded to 2dp, so rounding it again for the chart
    # moved the value: 12/961 is 1.2487, which the page shows as 1.2% while the chart
    # showed 1.3%. Both now come from the unrounded figure.
    report = build_report(status: :completed, completeness: :complete, passed: 12, total: 961)

    get report_path(report)
    expect(response.body).to include("1.2%")

    get asr_history_report_path(report, format: :json)
    expect(JSON.parse(response.body)["asr_values"]).to eq([ 1.2 ])
  end

  it "leaves a gap rather than plotting zero for a report with nothing to measure" do
    # A false 0.0 on the chart reads as a perfect result; the page says N/A for the
    # same report, so the series must not assert a number it cannot support.
    report = build_report(status: :completed, completeness: :complete, passed: 0, total: 0)

    get asr_history_report_path(report, format: :json)

    expect(JSON.parse(response.body)["asr_values"]).to eq([ nil ])
  end

  it "does not grade risk for a report whose rate cannot be calculated" do
    # detector rows exist but sum to zero: the band rendered "Low Risk" beside "N/A".
    report = ActsAsTenant.with_tenant(company) do
      r = create(:report, company: company, scan: scan, target: target,
                          status: :completed, result_completeness: :complete)
      create(:detector_result, report: r, detector: detector, passed: 0, total: 0)
      create(:probe_result, report: r, probe: create(:probe), detector: detector, passed: 0, total: 0)
      r
    end

    get report_detail_path(report)

    expect(response.body).to include("N/A")
    expect(response.body).not_to match(/Low Risk/i)
  end

  it "omits the run-over-run delta when either side has no rate to compare" do
    # attack_success_rate collapses an unmeasurable report to 0, so subtracting produced
    # "N/A" beside "50 pts vs last scan" -- a movement against a number that does not exist.
    ActsAsTenant.with_tenant(company) do
      previous = create(:report, company: company, scan: scan, target: target,
                                 status: :completed, result_completeness: :complete,
                                 created_at: 2.days.ago)
      create(:probe_result, report: previous, probe: probe, detector: detector, passed: 5, total: 10)
      create(:detector_result, report: previous, detector: detector, passed: 5, total: 10)
      create(:probe_result, report: previous, probe: create(:probe), detector: detector, passed: 5, total: 10)

      current = create(:report, company: company, scan: scan, target: target,
                                status: :completed, result_completeness: :complete)
      create(:detector_result, report: current, detector: detector, passed: 0, total: 0)
      create(:probe_result, report: current, probe: create(:probe), detector: detector, passed: 0, total: 0)

      expect(current.asr).not_to be_calculable
      expect(current.asr_delta_vs_previous).to be_nil
    end
  end

  it "still reports a delta when both sides can be calculated" do
    ActsAsTenant.with_tenant(company) do
      previous = create(:report, company: company, scan: scan, target: target,
                                 status: :completed, result_completeness: :complete,
                                 created_at: 2.days.ago)
      create(:detector_result, report: previous, detector: detector, passed: 5, total: 10)
      create(:probe_result, report: previous, probe: create(:probe), detector: detector, passed: 5, total: 10)

      current = create(:report, company: company, scan: scan, target: target,
                                status: :completed, result_completeness: :complete)
      create(:detector_result, report: current, detector: detector, passed: 8, total: 10)
      create(:probe_result, report: current, probe: create(:probe), detector: detector, passed: 8, total: 10)

      expect(current.asr_delta_vs_previous).to eq(30.0)
    end
  end

  it "labels lifecycle and completeness the same way on the list and the overview" do
    # AC 1: both surfaces read the labels from the same helper, so a partial run cannot
    # be a plain "failed" on one page and "failed + partial results" on the other.
    report = build_report(status: :failed, completeness: :partial, passed: 5959, total: 7866)

    get reports_path
    expect(response.body).to match(/partial results/i)

    get report_path(report)
    expect(response.body).to match(/partial results/i)
  end

  it "keeps a valid zero distinguishable from an unmeasurable one on the list" do
    measured_zero = build_report(status: :completed, completeness: :complete, passed: 0, total: 3)
    unmeasurable  = build_report(status: :failed, completeness: :none, passed: 0, total: 0)

    expect(measured_zero.asr.calculable?).to be true
    expect(measured_zero.asr.percent).to eq(0.0)
    expect(unmeasurable.asr.calculable?).to be false
    expect(unmeasurable.asr.percent).to be_nil
  end
end
