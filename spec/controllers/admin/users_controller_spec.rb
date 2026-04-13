# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::UsersController, type: :controller do
  render_views

  let!(:company_a) { create(:company, name: "Company A", tier: :tier_2) }
  let!(:company_b) { create(:company, name: "Company B", tier: :tier_3) }
  let!(:super_admin) { create(:user, :super_admin, company: company_a) }
  let!(:regular_user) { create(:user, company: company_a) }
  let!(:company_b_user) { create(:user, company: company_b) }

  describe "GET #index" do
    context "as super admin" do
      before do
        super_admin.update!(current_company: company_a)
        sign_in super_admin
        ActsAsTenant.current_tenant = company_a
      end

      it "returns success" do
        get :index
        expect(response).to have_http_status(:success)
      end

      it "shows all users across companies" do
        get :index
        # Super admin sees users from all companies
        expect(response.body).to include(super_admin.email)
        expect(response.body).to include(regular_user.email)
        expect(response.body).to include(company_b_user.email)
      end

      it "shows company column for super admin" do
        get :index
        expect(response.body).to include("Company A")
        expect(response.body).to include("Company B")
      end
    end

    context "as regular user" do
      before do
        regular_user.update!(current_company: company_a)
        sign_in regular_user
        ActsAsTenant.current_tenant = company_a
      end

      it "returns success" do
        get :index
        expect(response).to have_http_status(:success)
      end

      it "shows only same-company users" do
        get :index
        expect(response.body).to include(regular_user.email)
        expect(response.body).not_to include(company_b_user.email)
      end
    end
  end

  describe "GET #show" do
    context "as super admin" do
      before do
        super_admin.update!(current_company: company_a)
        sign_in super_admin
        ActsAsTenant.current_tenant = company_a
      end

      it "can view any user" do
        get :show, params: { id: company_b_user.id }
        expect(response).to have_http_status(:success)
        expect(response.body).to include(company_b_user.email)
      end
    end

    context "as regular user" do
      before do
        regular_user.update!(current_company: company_a)
        sign_in regular_user
        ActsAsTenant.current_tenant = company_a
      end

      it "can view same-company user" do
        get :show, params: { id: super_admin.id }
        expect(response).to have_http_status(:success)
      end

      it "cannot view different-company user" do
        get :show, params: { id: company_b_user.id }
        # Should redirect with alert (user not found in policy scope)
        expect(response).to redirect_to(users_path)
      end
    end
  end

  describe "GET #new" do
    context "as super admin" do
      before do
        super_admin.update!(current_company: company_a)
        sign_in super_admin
        ActsAsTenant.current_tenant = company_a
      end

      it "returns success" do
        get :new
        expect(response).to have_http_status(:success)
      end
    end
  end

  describe "POST #create" do
    let(:valid_user_params) do
      {
        user: {
          email: "newuser@example.com",
          password: "password123",
          password_confirmation: "password123"
        }
      }
    end

    context "as super admin" do
      before do
        super_admin.update!(current_company: company_a)
        sign_in super_admin
        ActsAsTenant.current_tenant = company_a
      end

      it "creates a new user" do
        expect {
          post :create, params: valid_user_params
        }.to change(User, :count).by(1)
      end

      it "can assign user to different company" do
        params = valid_user_params.deep_merge(user: { current_company_id: company_b.id })
        post :create, params: params
        expect(User.find_by(email: "newuser@example.com").current_company).to eq(company_b)
      end
    end

    context "as regular user" do
      before do
        regular_user.update!(current_company: company_a)
        sign_in regular_user
        ActsAsTenant.current_tenant = company_a
      end

      it "denies user creation" do
        expect {
          post :create, params: valid_user_params
        }.not_to change(User, :count)
      end
    end

    context "as OAuth user" do
      let!(:oauth_user) { create(:user, company: company_a, external_id: "oauth-uuid-123") }

      before do
        oauth_user.update!(current_company: company_a)
        sign_in oauth_user
        ActsAsTenant.current_tenant = company_a
      end

      it "denies user creation (only super admins can create users)" do
        expect {
          post :create, params: valid_user_params
        }.not_to change(User, :count)
      end
    end

    context "as OAuth super admin" do
      let!(:oauth_super_admin) { create(:user, :super_admin, company: company_a, external_id: "oauth-sa-uuid") }

      before do
        oauth_super_admin.update!(current_company: company_a)
        sign_in oauth_super_admin
        ActsAsTenant.current_tenant = company_a
      end

      it "can still create users" do
        expect {
          post :create, params: valid_user_params
        }.to change(User, :count).by(1)
      end
    end
  end

  describe "DELETE #destroy" do
    context "as super admin" do
      before do
        super_admin.update!(current_company: company_a)
        sign_in super_admin
        ActsAsTenant.current_tenant = company_a
      end

      it "can delete regular user" do
        expect {
          delete :destroy, params: { id: regular_user.id }
        }.to change(User, :count).by(-1)
      end

      # Note: Self-deletion protection is tested in policy specs
    end

    context "as regular user" do
      let!(:same_company_user) { create(:user, company: company_a) }

      before do
        regular_user.update!(current_company: company_a)
        sign_in regular_user
        ActsAsTenant.current_tenant = company_a
      end

      it "cannot delete same-company user (only super_admins can delete users)" do
        expect {
          delete :destroy, params: { id: same_company_user.id }
        }.not_to change(User, :count)
      end
    end

    context "as OAuth user" do
      let!(:oauth_user) { create(:user, company: company_a, external_id: "oauth-uuid-456") }
      let!(:same_company_target) { create(:user, company: company_a) }

      before do
        oauth_user.update!(current_company: company_a)
        sign_in oauth_user
        ActsAsTenant.current_tenant = company_a
      end

      it "cannot delete same-company user (only super_admins can delete users)" do
        expect {
          delete :destroy, params: { id: same_company_target.id }
        }.not_to change(User, :count)
      end
    end
  end
end
