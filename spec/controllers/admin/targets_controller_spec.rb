# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::TargetsController, type: :controller do
  let!(:company) { create(:company, name: "Test Company", tier: :tier_2) }
  let!(:user) { create(:user, company: company) }

  before do
    user.update!(current_company: company)
    sign_in user
    ActsAsTenant.current_tenant = company
  end

  describe "POST #create" do
    let(:valid_params) do
      {
        target: {
          name: "Test Target",
          model_type: "OpenAIGenerator",
          model: "gpt-3.5-turbo",
          description: "A test target"
        }
      }
    end

    it "creates a target with permitted params" do
      expect {
        post :create, params: valid_params
      }.to change(Target, :count).by(1)
    end

    it "does not allow setting status through params" do
      post :create, params: valid_params.deep_merge(target: { status: "good" })
      target = Target.last
      expect(target.status).not_to eq("good")
    end

    it "ignores status param and uses default status" do
      post :create, params: valid_params.deep_merge(target: { status: "good" })
      target = Target.last
      expect(target.status).to eq("validating")
    end
  end

  describe "PATCH #update" do
    let!(:target) { create(:target, company: company, name: "Original") }

    it "updates permitted attributes" do
      patch :update, params: { id: target.id, target: { name: "Updated" } }
      expect(target.reload.name).to eq("Updated")
    end

    it "does not allow changing status through params" do
      target.update_column(:status, Target.statuses[:bad])
      patch :update, params: { id: target.id, target: { status: "good", name: "Updated" } }
      target.reload
      expect(target.status).to eq("bad")
      expect(target.name).to eq("Updated")
    end

    it "does not allow bypassing validation by setting status to good" do
      patch :update, params: { id: target.id, target: { status: "good" } }
      target.reload
      expect(target.status).not_to eq("good")
    end
  end
end
