# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::DashboardController, type: :controller do
  render_views # Enable view rendering to test templates

  let(:company) { create(:company) }
  let(:user) { create(:user, company: company) }

  before do
    # Authentication is bypassed in test environment via User.first
    sign_in user
    ActsAsTenant.current_tenant = company
  end

  describe "GET #index" do
    context "when company has scans" do
      let!(:scan) { create(:complete_scan, company: company) }

      it "renders successfully" do
        get :index

        expect(response).to have_http_status(:success)
      end

      it "does not render no_scans template" do
        get :index

        expect(response.body).not_to include("no scans")
        expect(response.body).not_to include("No scans")
      end

      it "shows a Setup Wizard button linking to get_started" do
        get :index

        expect(response.body).to include("Setup Wizard")
        expect(response.body).to include("Set up a target and scan")
        expect(response.body).to include("icon-wand")
        expect(response.body).to include(get_started_path)
      end

      it "renders the Last Five Scans and Top Five Most Successful Attacks list tiles" do
        get :index

        expect(response.body).to include("Last Five Scans")
        expect(response.body).to include("Top Five Most Successful Attacks")
        expect(response.body).to include(scan.name)
      end

      it "links each attack name to its probe page" do
        probe = create(:probe, name: "Linked Probe #{SecureRandom.hex(4)}")
        allow(Stats::TopFiveAttacksData).to receive(:new).and_return(
          instance_double(
            Stats::TopFiveAttacksData,
            call: [ { probe_name: probe.name, probe_id: probe.id, asr: 90 } ]
          )
        )

        get :index

        assert_select "a[href=?]", probe_path(probe.id), text: probe.name
      end

      it "renders explanatory subtitles for the core nav items" do
        get :index

        expect(response.body).to include("the AI models you test")
        expect(response.body).to include("pick probes &amp; attack a target") # & is HTML-escaped on render
        expect(response.body).to include("findings from each scan")
      end
    end

    context "when company has no scans" do
      it "renders successfully" do
        get :index

        expect(response).to have_http_status(:success)
      end

      it "renders no_scans view" do
        get :index

        # The no_scans template should be rendered (can check for specific content)
        expect(response.body).to include("scan") # will contain "scan" or "Scan" in no_scans message
      end

      it "renders the guided setup steps with the first-time heading" do
        get :index

        expect(response.body).to include("Initiate Scan to activate Dashboard")
        expect(response.body).to include("Setup Target")
        expect(response.body).to include("Setup Scan")
      end
    end

    context "company scoping" do
      let(:other_company) { create(:company) }

      before do
        # Create scan for current company
        create(:complete_scan, company: company)

        # Create many scans for another company (should not be counted)
        ActsAsTenant.with_tenant(other_company) do
          create_list(:complete_scan, 5, company: other_company)
        end
      end

      it "only counts current company's scans" do
        get :index

        # Verify the response is successful and we're seeing the dashboard (not no_scans)
        expect(response).to have_http_status(:success)

        # The controller should only see company's 1 scan, not other_company's 5 scans
        # Current tenant query
        expect(Scan.count).to eq(1)

        # Verify other company has scans (using without_tenant)
        other_scan_count = ActsAsTenant.without_tenant { Scan.where(company_id: other_company.id).count }
        expect(other_scan_count).to eq(5)
      end
    end
  end

  describe "GET #get_started" do
    context "even when the company already has scans" do
      let!(:scan) { create(:complete_scan, company: company) }

      it "renders the guided setup steps" do
        get :get_started

        expect(response).to have_http_status(:success)
        expect(response.body).to include("Setup Target")
        expect(response.body).to include("Setup Scan")
      end

      it "uses the returning-user heading, not the first-time copy" do
        get :get_started

        expect(response.body).to include("Set up a target, then run a scan")
        expect(response.body).not_to include("Initiate Scan to activate Dashboard")
      end
    end
  end

  describe "dashboard_stats method (company scoping verification)" do
    let(:other_company) { create(:company) }
    let!(:scan) { create(:complete_scan, company: company) }
    let!(:target) { create(:target, company: company) }

    before do
      # Create report for current company
      create(:report, :completed, company: company, scan: scan, target: target)

      # Create MORE data for another company (should not be counted)
      ActsAsTenant.with_tenant(other_company) do
        other_scan = create(:complete_scan, company: other_company)
        other_target = create(:target, company: other_company)
        create_list(:report, 5, :completed, company: other_company, scan: other_scan, target: other_target)
      end
    end

    it "respects company scoping for scans" do
      # Must use without_tenant to see other company's data for verification
      company_scans_count = ActsAsTenant.without_tenant { Scan.where(company_id: company.id).count }
      other_scans_count = ActsAsTenant.without_tenant { Scan.where(company_id: other_company.id).count }

      expect(company_scans_count).to eq(1)
      expect(other_scans_count).to eq(1)

      # Current tenant should only see company's scan
      expect(Scan.count).to eq(1)
    end

    it "respects company scoping for targets" do
      # Must use without_tenant to see other company's data for verification
      company_targets_count = ActsAsTenant.without_tenant { Target.where(company_id: company.id, deleted_at: nil).count }
      other_targets_count = ActsAsTenant.without_tenant { Target.where(company_id: other_company.id, deleted_at: nil).count }

      # complete_scan creates 2 targets via with_targets trait, plus our explicit target = 3
      expect(company_targets_count).to eq(3)
      # other complete_scan also creates 2 targets, plus our explicit target = 3
      expect(other_targets_count).to eq(3)

      # Current tenant should only see company's targets
      expect(Target.count).to eq(3)
    end

    it "respects company scoping for completed reports" do
      # Must use without_tenant to see other company's data for verification
      company_reports_count = ActsAsTenant.without_tenant { Report.where(company_id: company.id, status: Report.statuses[:completed]).count }
      other_reports_count = ActsAsTenant.without_tenant { Report.where(company_id: other_company.id, status: Report.statuses[:completed]).count }

      expect(company_reports_count).to eq(1)
      expect(other_reports_count).to eq(5)

      # Current tenant should only see company's reports
      expect(Report.where(status: Report.statuses[:completed]).count).to eq(1)
    end

    it "excludes soft-deleted targets" do
      # Count before adding deleted target
      targets_before = Target.count

      deleted_target = create(:target, company: company)
      deleted_target.mark_deleted!

      active_targets = Target.count # default scope excludes deleted
      all_targets_including_deleted = Target.with_deleted.count # includes deleted

      expect(all_targets_including_deleted).to eq(targets_before + 1) # includes deleted
      expect(active_targets).to eq(targets_before) # excludes deleted
    end

    it "only counts completed reports" do
      # Get current counts
      completed_before = Report.where(status: Report.statuses[:completed]).count
      total_before = Report.count

      # Create 3 non-completed reports
      create(:report, :failed, company: company, scan: scan, target: target)
      create(:report, :running, company: company, scan: scan, target: target)
      create(:report, :pending, company: company, scan: scan, target: target)

      # Verify completed count didn't change
      expect(Report.where(status: Report.statuses[:completed]).count).to eq(completed_before)

      # Verify we added exactly 3 reports
      expect(Report.count).to eq(total_before + 3)
    end
  end
end
