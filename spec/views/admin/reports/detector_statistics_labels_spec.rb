# frozen_string_literal: true

require "rails_helper"

RSpec.describe "admin/reports/_statistics_section", type: :view do
  # The reported confusion: one report showed two rows both reading "Generic Mitigation
  # Bypass Checks" with different numbers (4/4 and 185/185), and a probe row of 4/180
  # beside a detector row of 180/180 for related work. Both distinctions were real; the
  # page explained neither.
  let(:company) { create(:company) }
  let(:scan) { create(:complete_scan, company: company) }
  let(:target) { create(:target, company: company) }

  def detector_rows
    Nokogiri::HTML(rendered).css("table tbody tr").map { |tr| tr.css("td").first.text.squish }
  end

  it "tells apart two detectors that share a friendly name" do
    report = create(:report, company: company, scan: scan, target: target, status: :completed)
    odin = create(:detector, name: "0din.MitigationBypass")
    upstream = create(:detector, name: "mitigation.MitigationBypass")
    create(:detector_result, report: report, detector: odin, passed: 4, total: 4)
    create(:detector_result, report: report, detector: upstream, passed: 185, total: 185)

    render partial: "admin/reports/statistics_section", locals: { report: report }

    rows = detector_rows
    expect(rows.count { |r| r.include?("Generic Mitigation Bypass Checks") }).to eq(2)
    expect(rows.join).to include("0din.MitigationBypass")
    expect(rows.join).to include("mitigation.MitigationBypass")
  end

  it "states the level and grouping basis of the detector table" do
    report = create(:report, company: company, scan: scan, target: target, status: :completed)
    create(:detector_result, report: report, detector: create(:detector), passed: 1, total: 2)

    render partial: "admin/reports/statistics_section", locals: { report: report }

    expect(rendered).to match(/one row per detector/i)
    expect(rendered).to match(/outputs that detector evaluated/i)
  end

  it "does not repeat the identifier when the label already is the identifier" do
    # "divergence.Repeat" has no friendly mapping, so the row reads "Repeat"; the full
    # identifier still differs from the label and is worth showing.
    report = create(:report, company: company, scan: scan, target: target, status: :completed)
    create(:detector_result, report: report, detector: create(:detector, name: "Repeat"), passed: 1, total: 2)

    render partial: "admin/reports/statistics_section", locals: { report: report }

    expect(detector_rows.first).to eq("Repeat")
  end
end
