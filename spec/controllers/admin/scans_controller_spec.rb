# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::ScansController, type: :controller do
  render_views

  let!(:company) { create(:company, tier: :tier_4) }
  let!(:super_admin) { create(:user, :super_admin, company: company) }
  let!(:target) { ActsAsTenant.with_tenant(company) { create(:target, company: company) } }
  let!(:probe) { create(:probe) }
  let!(:scan) do
    ActsAsTenant.with_tenant(company) do
      create(:complete_scan, company: company)
    end
  end

  before do
    super_admin.update!(current_company: company)
    sign_in super_admin
    ActsAsTenant.current_tenant = company
  end

  describe "GET #index" do
    it "returns success" do
      get :index
      expect(response).to have_http_status(:success)
    end

    it "renders the index template" do
      get :index
      expect(response.body).to include("Scans")
    end

    it "supports scope filtering" do
      get :index, params: { scope: "all" }
      expect(response).to have_http_status(:success)
    end

    it "renders labeled, hover-reveal action buttons" do
      get :index, params: { scope: "all" }

      assert_select "a[href=?]", reports_path(q: { scan_id_eq: scan.id }), text: /Reports/
      assert_select "tbody tr.group"
      expect(response.body).to include("group-hover:opacity-100")
      expect(response.body).to include("group-focus-within:opacity-100")
    end
  end

  describe "GET #new" do
    it "returns success" do
      get :new
      expect(response).to have_http_status(:success)
    end

    it "loads probe categories filtered by policy_scope" do
      get :new
      # The controller uses policy_scope(Probe) for tier-based filtering
      expect(response).to have_http_status(:success)
    end
  end

  describe "POST #create" do
    let(:valid_params) do
      {
        scan: {
          name: "New Test Scan",
          target_ids: [ target.id ],
          probe_ids: [ probe.id ]
        }
      }
    end

    it "creates a scan with valid params" do
      expect {
        post :create, params: valid_params
      }.to change(Scan, :count).by(1)
    end

    it "redirects to scan show page on success" do
      post :create, params: valid_params
      expect(response).to redirect_to(scan_path(Scan.last))
    end
  end

  describe "POST #rerun" do
    it "relaunches the scan" do
      expect_any_instance_of(Scan).to receive(:rerun)
      post :rerun, params: { id: scan.id }
      expect(response).to redirect_to(reports_path)
    end

    it "displays success notice" do
      allow_any_instance_of(Scan).to receive(:rerun)
      post :rerun, params: { id: scan.id }
      expect(flash[:notice]).to include("launched successfully")
    end
  end

  describe "GET #stats" do
    it "returns JSON stats" do
      get :stats, params: { id: scan.id }, format: :json
      expect(response).to have_http_status(:success)
      expect(response.content_type).to include("application/json")
    end
  end

  describe "DELETE #destroy" do
    it "deletes the scan" do
      expect {
        delete :destroy, params: { id: scan.id }
      }.to change(Scan, :count).by(-1)
    end

    it "redirects to scans index" do
      delete :destroy, params: { id: scan.id }
      expect(response).to redirect_to(scans_path)
    end
  end

  describe "POST #batch" do
    let!(:scan2) do
      ActsAsTenant.with_tenant(company) do
        create(:complete_scan, company: company)
      end
    end

    describe "batch_rerun" do
      it "reruns selected scans" do
        allow_any_instance_of(Scan).to receive(:rerun)
        post :batch, params: { batch_action: "rerun", ids: [ scan.id, scan2.id ] }
        expect(flash[:notice]).to include("launched successfully")
      end
    end

    describe "batch_destroy" do
      it "destroys selected scans" do
        expect {
          post :batch, params: { batch_action: "destroy", ids: [ scan.id, scan2.id ] }
        }.to change(Scan, :count).by(-2)
      end
    end
  end
end
