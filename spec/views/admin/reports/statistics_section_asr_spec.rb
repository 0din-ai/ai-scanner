# frozen_string_literal: true

require "rails_helper"

RSpec.describe "admin/reports/_statistics_section", type: :view do
  # The text moved to the canonical figure but the colour still came from
  # attack_success_rate, which rounds and collapses zero -- so an unavailable rate wore
  # the zero-ASR colour, and a rate just under a threshold could be coloured for the
  # band above the one it is graded in.
  let(:company) { create(:company) }
  let(:scan) { create(:complete_scan, company: company) }
  let(:target) { create(:target, company: company) }
  let(:detector) { create(:detector) }

  # The value span sits beside its label, so assert on that element rather than on the
  # whole partial: several unrelated elements carry the same utility classes.
  def asr_cell(passed:, total:)
    report = create(:report, company: company, scan: scan, target: target, status: :completed)
    create(:detector_result, report: report, detector: detector, passed: passed, total: total) if total.positive?
    render partial: "admin/reports/statistics_section", locals: { report: report }

    label = Nokogiri::HTML.fragment(rendered).css("span").find { |s| s.text.strip == "Attack Success Rate" }
    raise "ASR row not found" unless label

    label.parent.css("span").last
  end

  it "colours an unavailable rate as unavailable, not as zero" do
    cell = asr_cell(passed: 0, total: 0)

    expect(cell.text.strip).to eq("N/A")
    expect(cell["class"]).to include("text-contentSecondary")
  end

  it "colours a rate just below a threshold with the band it actually falls in" do
    # 2000/8001 is 24.9969%: below 25, so the low band -- even though the displayed
    # figure rounds to 25.0%.
    cell = asr_cell(passed: 2000, total: 8001)

    expect(cell.text.strip).to eq("25.0%")
    expect(cell["class"]).to include("text-[#71717A]")
  end
end
