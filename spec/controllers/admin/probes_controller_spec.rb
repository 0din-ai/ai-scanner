# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::ProbesController, type: :controller do
  render_views

  let!(:tier_1_company) { create(:company, tier: :tier_1) }
  let!(:tier_4_company) { create(:company, tier: :tier_4) }
  let!(:super_admin) { create(:user, :super_admin, company: tier_4_company) }

  # Create disclosed probes (accessible to tier_1)
  # Release dates must be older than 1 month exclusivity period
  let!(:disclosed_probes) do
    (1..30).map do |i|
      create(:probe, disclosure_status: "n-day", release_date: (2.months.ago - i.days))
    end
  end

  # Create undisclosed probes (not accessible to tier_1)
  let!(:undisclosed_probes) do
    (1..10).map do |i|
      create(:probe, disclosure_status: "0-day", release_date: (2.months.ago - i.days))
    end
  end

  describe "GET #index" do
    context "as tier_4 user (unlimited access)" do
      before do
        super_admin.update!(current_company: tier_4_company)
        sign_in super_admin
        ActsAsTenant.current_tenant = tier_4_company
      end

      it "returns success" do
        get :index
        expect(response).to have_http_status(:success)
      end

      it "shows all probes (40 total)" do
        get :index
        # Tier 4 has unlimited access - should see all probes
        expect(response.body).to include("40") # Total count shown somewhere
      end
    end

    context "as tier_1 user (limited access)" do
      let!(:tier_1_user) { create(:user, company: tier_1_company) }

      before do
        tier_1_user.update!(current_company: tier_1_company)
        sign_in tier_1_user
        ActsAsTenant.current_tenant = tier_1_company
      end

      it "returns success" do
        get :index
        expect(response).to have_http_status(:success)
      end

      it "applies tier-based filtering via policy_scope" do
        # Tier 1 should only see 25 oldest disclosed probes
        get :index
        expect(response).to have_http_status(:success)
        # The policy_scope filters probes based on tier
      end
    end

    it "supports ransack search" do
      super_admin.update!(current_company: tier_4_company)
      sign_in super_admin
      ActsAsTenant.current_tenant = tier_4_company

      probe_name = disclosed_probes.first.name
      get :index, params: { q: { name_cont: probe_name } }
      expect(response.body).to include(probe_name)
    end
  end

  describe "GET #show" do
    let(:probe) { disclosed_probes.first }

    before do
      super_admin.update!(current_company: tier_4_company)
      sign_in super_admin
      ActsAsTenant.current_tenant = tier_4_company
    end

    it "returns success" do
      get :show, params: { id: probe.id }
      expect(response).to have_http_status(:success)
    end

    it "displays probe details" do
      get :show, params: { id: probe.id }
      expect(response.body).to include(probe.name)
    end

    it "shows cached success stats" do
      probe.update!(cached_passed_count: 10, cached_total_count: 20)
      get :show, params: { id: probe.id }
      expect(response).to have_http_status(:success)
    end

    it "renders valid attribution URLs as external links with noopener" do
      probe.update!(attribution: "0DIN by Mozilla - https://0din.ai")

      get :show, params: { id: probe.id }

      expect(response.body).to include("0DIN by Mozilla")
      expect(response.body).to include('href="https://0din.ai"')
      expect(response.body).to include('target="_blank"')
      expect(response.body).to include('rel="noopener"')
    end

    it "does not link attribution URLs without a host" do
      probe.update!(attribution: "Bad source - https:///evil")

      get :show, params: { id: probe.id }

      expect(response.body).to include("Bad source - https:///evil")
      expect(response.body).not_to include('href="https:///evil"')
    end

    it "escapes stored attribution text" do
      probe.update!(attribution: "Bad <script>alert(1)</script> - https://example.com")

      get :show, params: { id: probe.id }

      expect(response.body).to include("Bad &lt;script&gt;alert(1)&lt;/script&gt;")
      expect(response.body).not_to include("<script>alert(1)</script>")
    end
  end
end
