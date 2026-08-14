# frozen_string_literal: true

require "rails_helper"

RSpec.describe AdminHelper, type: :helper do
  describe "#report_has_viewable_results?" do
    # The partial notice, metrics and PDF are only reachable if the list and header
    # offer the links. Gating them on completed? hides exactly the reports this
    # change exists to explain.
    let(:vr_scan) { create(:complete_scan) }
    let(:vr_target) { create(:target) }

    it "is true for a completed report" do
      report = create(:report, scan: vr_scan, target: vr_target, status: :completed, result_completeness: :complete)

      expect(helper.report_has_viewable_results?(report)).to be true
    end

    it "is true for a failed report holding partial results" do
      report = create(:report, scan: vr_scan, target: vr_target, status: :failed, result_completeness: :partial)

      expect(helper.report_has_viewable_results?(report)).to be true
    end

    it "is true when completeness is unknown but results exist" do
      # A failure with no plan to compare against stays unclassified. Its results are
      # real either way, and hiding the links would make them unreachable.
      parent = create(:report, scan: vr_scan, target: vr_target, status: :completed)
      report = create(:report, scan: vr_scan, target: vr_target, status: :failed,
                               result_completeness: nil, failure_code: "provider_rate_limited",
                               parent_report_id: parent.id)
      create(:probe_result, report: report, probe: create(:probe))
      # Completeness is recorded as a report turns terminal, so an unresolved row has to
      # be made deliberately: this one has results but no denominator to judge them by.
      report.update_columns(result_completeness: nil)

      expect(helper.report_has_viewable_results?(report.reload)).to be true
    end

    it "is false for a failed report with nothing recorded" do
      report = create(:report, scan: vr_scan, target: vr_target, status: :failed, result_completeness: :none)

      expect(helper.report_has_viewable_results?(report)).to be false
    end

    it "resolves an unclassified row without re-deriving for every predicate" do
      # The admin index renders this helper and the lifecycle tags on every row. A row
      # that stays unclassified falls through each predicate in turn, and re-deriving
      # per call means a fresh probe_results query each time -- ~5 a row, so a 20-row
      # page pays ~100 extra queries.
      parent = create(:report, scan: vr_scan, target: vr_target, status: :completed)
      report = create(:report, scan: vr_scan, target: vr_target, status: :failed,
                               result_completeness: nil, failure_code: "provider_rate_limited",
                               parent_report_id: parent.id)
      create(:probe_result, report: report, probe: create(:probe))
      report.reload

      queries = 0
      counter = ->(_n, _s, _f, _i, payload) { queries += 1 if payload[:sql].to_s.include?("probe_results") }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        helper.report_has_viewable_results?(report)
        helper.report_lifecycle_tags(report)
      end

      expect(queries).to be <= 2
    end
  end

  describe "#report_lifecycle_tags" do
    # Lifecycle and completeness are separate facts, so the list shows both: a failed
    # report holding partial evidence must not read the same as one holding nothing.
    let(:scan) { create(:complete_scan) }
    let(:target) { create(:target) }

    it "shows only the lifecycle for a completed report" do
      report = create(:report, scan: scan, target: target, status: :completed, result_completeness: :complete)

      expect(helper.report_lifecycle_tags(report)).to match(/completed/i)
      expect(helper.report_lifecycle_tags(report)).not_to match(/partial/i)
    end

    it "marks a failed report holding results as partial" do
      report = create(:report, scan: scan, target: target, status: :failed, result_completeness: :partial)

      expect(helper.report_lifecycle_tags(report)).to match(/partial/i)
    end

    it "does not mark a failed report with no results as partial" do
      report = create(:report, scan: scan, target: target, status: :failed, result_completeness: :none)

      expect(helper.report_lifecycle_tags(report)).not_to match(/partial/i)
    end
  end

  describe "#status_tag" do
    describe "explicit status" do
      it "renders ok status with green styling" do
        result = helper.status_tag("Active", :ok)
        expect(result).to include("bg-lime-950")
        expect(result).to include("text-lime-400")
        expect(result).to include("Active")
      end

      it "renders yes status with green styling" do
        result = helper.status_tag("Enabled", :yes)
        expect(result).to include("bg-lime-950")
        expect(result).to include("text-lime-400")
      end

      it "renders warning status with yellow styling" do
        result = helper.status_tag("Pending", :warning)
        expect(result).to include("bg-zinc-800")
        expect(result).to include("text-zinc-400")
      end

      it "renders error status with red styling" do
        result = helper.status_tag("Failed", :error)
        expect(result).to include("bg-red-950")
        expect(result).to include("text-red-400")
      end

      it "renders no status with red styling" do
        result = helper.status_tag("Disabled", :no)
        expect(result).to include("bg-red-950")
        expect(result).to include("text-red-400")
      end

      it "renders true as green" do
        result = helper.status_tag("Yes", true)
        expect(result).to include("bg-lime-950")
        expect(result).to include("text-lime-400")
      end

      it "renders false as red" do
        result = helper.status_tag("No", false)
        expect(result).to include("bg-red-950")
        expect(result).to include("text-red-400")
      end
    end

    describe "auto-detection from text" do
      it "detects completed as green" do
        result = helper.status_tag("completed")
        expect(result).to include("bg-lime-950")
        expect(result).to include("text-lime-400")
        expect(result).to include("Completed")
      end

      it "detects success as green" do
        result = helper.status_tag("success")
        expect(result).to include("bg-lime-950")
        expect(result).to include("text-lime-400")
      end

      it "detects active as green" do
        result = helper.status_tag("active")
        expect(result).to include("bg-lime-950")
        expect(result).to include("text-lime-400")
      end

      it "detects enabled as green" do
        result = helper.status_tag("enabled")
        expect(result).to include("bg-lime-950")
        expect(result).to include("text-lime-400")
      end

      it "detects passed as green" do
        result = helper.status_tag("passed")
        expect(result).to include("bg-lime-950")
        expect(result).to include("text-lime-400")
      end

      it "detects pending as blue" do
        result = helper.status_tag("pending")
        expect(result).to include("bg-zinc-800")
        expect(result).to include("text-zinc-400")
      end

      it "detects processing as blue" do
        result = helper.status_tag("processing")
        expect(result).to include("bg-zinc-800")
        expect(result).to include("text-zinc-400")
      end

      it "detects in_progress as blue" do
        result = helper.status_tag("in_progress")
        expect(result).to include("bg-zinc-800")
        expect(result).to include("text-zinc-400")
      end

      it "detects running as blue" do
        result = helper.status_tag("running")
        expect(result).to include("bg-zinc-800")
        expect(result).to include("text-zinc-400")
      end

      it "detects failed as red" do
        result = helper.status_tag("failed")
        expect(result).to include("bg-red-950")
        expect(result).to include("text-red-400")
      end

      it "detects error as red" do
        result = helper.status_tag("error")
        expect(result).to include("bg-red-950")
        expect(result).to include("text-red-400")
      end

      it "detects disabled as red" do
        result = helper.status_tag("disabled")
        expect(result).to include("bg-red-950")
        expect(result).to include("text-red-400")
      end

      it "detects deleted as red" do
        result = helper.status_tag("deleted")
        expect(result).to include("bg-red-950")
        expect(result).to include("text-red-400")
      end

      it "detects cancelled as red" do
        result = helper.status_tag("cancelled")
        expect(result).to include("bg-red-950")
        expect(result).to include("text-red-400")
      end

      it "detects warning as yellow" do
        result = helper.status_tag("warning")
        expect(result).to include("bg-zinc-800")
        expect(result).to include("text-zinc-400")
      end

      it "detects paused as yellow" do
        result = helper.status_tag("paused")
        expect(result).to include("bg-zinc-800")
        expect(result).to include("text-zinc-400")
      end

      it "detects stopped as yellow" do
        result = helper.status_tag("stopped")
        expect(result).to include("bg-zinc-800")
        expect(result).to include("text-zinc-400")
      end

      it "detects interrupted as gray" do
        result = helper.status_tag("interrupted")
        expect(result).to include("bg-zinc-800")
        expect(result).to include("text-zinc-400")
        expect(result).to include("Interrupted")
      end

      it "falls back to gray for unknown text" do
        result = helper.status_tag("unknown_status")
        expect(result).to include("bg-zinc-800")
        expect(result).to include("text-zinc-400")
      end
    end

    describe "HTML structure" do
      it "renders as a span element" do
        result = helper.status_tag("Test")
        expect(result).to match(/<span.*>Test<\/span>/)
      end

      it "includes rounded-md class" do
        result = helper.status_tag("Test")
        expect(result).to include("rounded-md")
      end

      it "includes text-xs class" do
        result = helper.status_tag("Test")
        expect(result).to include("text-xs")
      end

      it "includes font-medium class" do
        result = helper.status_tag("Test")
        expect(result).to include("font-medium")
      end

      it "humanizes the text" do
        result = helper.status_tag("in_progress")
        expect(result).to include("In progress")
      end
    end

    describe "dark mode support" do
      it "includes dark mode classes for green" do
        result = helper.status_tag("Active", :ok)
        expect(result).to include("dark:bg-lime-950")
        expect(result).to include("dark:text-lime-400")
      end

      it "includes dark mode classes for red" do
        result = helper.status_tag("Failed", :error)
        expect(result).to include("dark:bg-red-950")
        expect(result).to include("dark:text-red-400")
      end

      it "includes dark mode classes for yellow" do
        result = helper.status_tag("Warning", :warning)
        expect(result).to include("dark:bg-zinc-800")
        expect(result).to include("dark:text-zinc-400")
      end

      it "includes dark mode classes for gray" do
        result = helper.status_tag("unknown")
        expect(result).to include("dark:bg-zinc-800")
        expect(result).to include("dark:text-zinc-400")
      end
    end
  end

  describe "#html_head_site_title" do
    it "combines page title and site title" do
      @page_title = "Users"
      result = helper.html_head_site_title
      expect(result).to eq("Users - Scanner")
    end

    it "uses default page title if not set" do
      # controller_name would return something, but in test it may not be set
      allow(helper).to receive(:page_title).and_return("Test Page")
      result = helper.html_head_site_title
      expect(result).to include("Scanner")
    end
  end

  describe "#site_title" do
    it "returns Scanner" do
      expect(helper.site_title).to eq("Scanner")
    end
  end

  describe "#page_title" do
    it "returns @page_title if set" do
      @page_title = "Custom Title"
      expect(helper.page_title).to eq("Custom Title")
    end

    it "returns titleized controller name as default" do
      allow(helper).to receive(:controller_name).and_return("users")
      expect(helper.page_title).to eq("Users")
    end
  end
end
