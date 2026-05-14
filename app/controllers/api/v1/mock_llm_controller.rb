module Api
  module V1
    class MockLlmController < ActionController::API
      def chat
        prompt = params[:text] || ""
        response_mode = request.headers["X-Mock-Mode"] || params[:mode] || "mixed"

        service = MockLlmService.new(prompt, response_mode)
        response_text = service.generate_response

        render json: { text: response_text }
      end

      def status
        render json: {
          status: "ok",
          service: "Mock LLM Interface",
          available_modes: [ "safe", "vulnerable", "mixed" ],
          description: "Mock LLM for scanner validation and testing"
        }
      end
    end
  end
end
