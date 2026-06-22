# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::EnvironmentVariablesController, type: :controller do
  let!(:company) { create(:company, tier: :tier_2) }
  let!(:user) { create(:user, :super_admin, company: company) }

  before do
    user.update!(current_company: company)
    sign_in user
    ActsAsTenant.current_tenant = company
  end

  describe "POST #batch_destroy" do
    it "destroys the current tenant's selected environment variables" do
      ours = ActsAsTenant.with_tenant(company) { create(:environment_variable, company: company) }

      expect {
        post :batch_destroy, params: { ids: [ ours.id ] }
      }.to change(EnvironmentVariable, :count).by(-1)
    end

    it "does NOT destroy another tenant's environment variable (cross-tenant guard)" do
      other_company = create(:company, tier: :tier_2)
      other_var = ActsAsTenant.with_tenant(other_company) { create(:environment_variable, company: other_company) }

      post :batch_destroy, params: { ids: [ other_var.id ] }

      survives = ActsAsTenant.without_tenant { EnvironmentVariable.where(id: other_var.id).exists? }
      expect(survives).to be(true)
    end
  end
end
