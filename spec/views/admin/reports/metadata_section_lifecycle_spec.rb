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

  it "shows only the lifecycle for a complete report" do
    report = create(:report, company: company, scan: scan, target: target,
                             status: :completed, result_completeness: :complete)

    render partial: "admin/reports/metadata_section", locals: { report: report }

    expect(rendered).not_to match(/partial results/i)
  end
end
