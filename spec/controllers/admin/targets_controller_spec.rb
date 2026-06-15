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

  describe "POST #auto_detect_selectors" do
    let(:session_id) do
      Rails.application.message_verifier(:auto_detect_session).generate([ user.id, SecureRandom.uuid ])
    end

    it "rejects blocked internal URLs before running auto-detection" do
      expect(AutoDetectWebchatSelectors).not_to receive(:new)

      post :auto_detect_selectors, params: {
        url: "http://169.254.169.254/latest/meta-data",
        session_id: session_id
      }, format: :json

      expect(response).to have_http_status(:bad_request)
      json = JSON.parse(response.body)
      expect(json["error"]).to include("blocked internal address")
    end

    it "forwards auth to the service and echoes it into the returned config" do
      auth = { "headers" => { "Authorization" => "Bearer x" } }
      detector = instance_double(AutoDetectWebchatSelectors)

      expect(AutoDetectWebchatSelectors).to receive(:new)
        .with("https://example.com/chat", hash_including(auth: hash_including("headers")))
        .and_return(detector)
      allow(detector).to receive(:call).and_return(
        selectors: { "input_field" => "#i", "response_container" => "#r", "response_text" => "" },
        screenshot: nil
      )

      post :auto_detect_selectors, params: {
        url: "https://example.com/chat",
        session_id: session_id,
        auth: auth
      }, format: :json

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig("config", "auth", "headers", "Authorization")).to eq("Bearer x")
    end

    it "sanitizes secrets from the error response when detection raises" do
      allow(AutoDetectWebchatSelectors).to receive(:new).and_raise(StandardError, "boom Bearer abcdef123456")

      post :auto_detect_selectors, params: {
        url: "https://example.com/chat",
        session_id: session_id
      }, format: :json

      expect(response).to have_http_status(:internal_server_error)
      expect(response.body).not_to include("abcdef123456")
      expect(JSON.parse(response.body)["error"]).to include("[REDACTED]")
    end
  end
end
