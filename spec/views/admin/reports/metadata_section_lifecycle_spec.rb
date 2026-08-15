# frozen_string_literal: true

require "rails_helper"

RSpec.describe "admin/reports/_metadata_section", type: :view do
  # AC 1: lifecycle and completeness labels come from one helper everywhere. The list
  # already used report_lifecycle_tags; the overview labelled status alone, so a partial
  # run read as a plain "failed" here while the list showed it as partial.
  let(:company) { create(:company) }
  let(:scan) { create(:complete_scan, company: company) }
  let(:target) { create(:target, company: company) }

  it "shows completeness beside the lifecycle for a partial report" do
    report = create(:report, company: company, scan: scan, target: target,
                             status: :failed, result_completeness: :partial)

    render partial: "admin/reports/metadata_section", locals: { report: report }

    expect(rendered).to match(/failed/i)
    expect(rendered).to match(/partial results/i)
  end

  describe "the UUID link" do
    # The list and the report header offer their Details affordance whenever usable
    # evidence exists, but this one still keyed on completed? -- so a failed report with
    # retained results showed "View Report" in its header and a dead plain-text UUID
    # right below it.
    def uuid_cell(report)
      render partial: "admin/reports/metadata_section", locals: { report: report }
      label = Nokogiri::HTML(rendered).css("span").find { |node| node.text.strip == "UUID:" }
      raise "UUID row not found" unless label

      label.parent
    end

    it "links to the details of a failed report that retained results" do
      report = create(:report, company: company, scan: scan, target: target,
                               status: :failed, result_completeness: :partial)

      expect(uuid_cell(report).css("a")).to be_present
    end

    it "leaves the UUID unlinked when nothing was retained" do
      report = create(:report, company: company, scan: scan, target: target,
                               status: :failed, result_completeness: :none)

      expect(uuid_cell(report).css("a")).to be_empty
    end

    it "still links a completed report" do
      report = create(:report, company: company, scan: scan, target: target,
                               status: :completed, result_completeness: :complete)

      expect(uuid_cell(report).css("a")).to be_present
    end
  end

  it "shows only the lifecycle for a complete report" do
    report = create(:report, company: company, scan: scan, target: target,
                             status: :completed, result_completeness: :complete)

    render partial: "admin/reports/metadata_section", locals: { report: report }

    expect(rendered).not_to match(/partial results/i)
  end
end
