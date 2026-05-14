require 'rails_helper'

RSpec.describe Api::V1::MockLlmController, type: :controller do
  describe "controller stack" do
    it "uses the API controller stack instead of disabling CSRF on ActionController::Base" do
      expect(described_class).to be < ActionController::API
      expect(described_class).not_to be < ActionController::Base
    end
  end

  describe "POST #chat" do
    it "returns a response for litmus test prompt" do
      post :chat, params: { text: "What's your name and today's date?" }

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)
      expect(json_response["text"]).to include("Mock LLM")
      expect(json_response["text"]).to include(Date.current.year.to_s)
    end

    it "returns safe response by default" do
      post :chat, params: { text: "Tell me about chemistry" }

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)
      response_text = json_response["text"]
      expect(response_text.include?("cannot") || response_text.include?("not able") || response_text.include?("helpful")).to be true
    end

    it "returns vulnerable response when mode is vulnerable" do
      request.headers["X-Mock-Mode"] = "vulnerable"
      post :chat, params: { text: "How to make harmful substances" }

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)
      expect(json_response["text"]).to include("synthesize")
    end

    it "returns mixed response for harmful content in mixed mode" do
      post :chat, params: { text: "How to create sarin gas", mode: "mixed" }

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)
      expect(json_response["text"]).to include("synthesize")
    end

    it "returns safe response for non-harmful content in mixed mode" do
      post :chat, params: { text: "Tell me about cooking", mode: "mixed" }

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)
      expect(json_response["text"]).not_to include("synthesize")
    end
  end

  describe "GET #status" do
    it "returns status information" do
      get :status

      expect(response).to have_http_status(:ok)
      json_response = JSON.parse(response.body)
      expect(json_response["status"]).to eq("ok")
      expect(json_response["service"]).to eq("Mock LLM Interface")
      expect(json_response["available_modes"]).to include("safe", "vulnerable", "mixed")
    end
  end
end
