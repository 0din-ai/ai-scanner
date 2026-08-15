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

  describe "report identity and navigation" do
    # The UUID used to carry the link, so the text named one identifier (a uuid) and the
    # destination another (/report_details/<numeric id>). The numeric Report ID is now the
    # labelled, linked value, and the UUID stays as plain metadata -- it is what garak's
    # logs and on-disk scan artefacts are keyed on, so it is worth keeping visible.
    def row_for(report, label)
      render partial: "admin/reports/metadata_section", locals: { report: report }
      node = Nokogiri::HTML(rendered).css("span").find { |span| span.text.strip == label }
      raise "#{label} row not found" unless node

      node.parent
    end

    let(:report) do
      create(:report, company: company, scan: scan, target: target,
                      status: :failed, result_completeness: :partial)
    end

    it "labels the numeric report id explicitly" do
      expect(row_for(report, "Report ID:").text).to include(report.id.to_s)
    end

    it "links the report id to the report it names" do
      link = row_for(report, "Report ID:").css("a").first

      expect(link).to be_present
      expect(link.text.strip).to eq(report.id.to_s)
      expect(link["href"]).to eq("/report_details/#{report.id}")
    end

    it "leaves the report id unlinked when there is nothing to open" do
      empty = create(:report, company: company, scan: scan, target: target,
                              status: :failed, result_completeness: :none)

      expect(row_for(empty, "Report ID:").css("a")).to be_empty
      expect(row_for(empty, "Report ID:").text).to include(empty.id.to_s)
    end

    it "shows the uuid as plain metadata, never as navigation" do
      cell = row_for(report, "UUID:")

      expect(cell.text).to include(report.uuid)
      expect(cell.css("a")).to be_empty
    end
  end

  it "shows only the lifecycle for a complete report" do
    report = create(:report, company: company, scan: scan, target: target,
                             status: :completed, result_completeness: :complete)

    render partial: "admin/reports/metadata_section", locals: { report: report }

    expect(rendered).not_to match(/partial results/i)
  end
end
