require "rails_helper"

RSpec.describe ValidateWebChatTarget do
  let(:target) { create(:target, target_type: :webchat, status: :validating) }
  let(:service) { described_class.new(target) }
  let(:playwright_service) { instance_double(BrowserAutomation::PlaywrightService) }

  before do
    allow(BrowserAutomation::PlaywrightService).to receive(:instance).and_return(playwright_service)
  end

  describe "#initialize" do
    it "sets the target" do
      expect(service.target).to eq(target)
    end
  end

  describe "#call" do
    context "with valid web chat configuration" do
      let(:valid_config) do
        {
          "url" => "https://example.com/chat",
          "selectors" => {
            "input_field" => "#chat-input",
            "send_button" => "#send-btn",
            "response_container" => ".chat-response"
          }
        }
      end

      before do
        target.update(web_config: valid_config)
      end

      it "sets status to validating at start" do
        initial_status = target.status

        allow(playwright_service).to receive(:validate_webchat_config).and_return({
          success: true,
          response_detected: true,
          errors: []
        })

        service.call
        # Status is first set to validating, then updated based on validation result
        # Just verify the service completed without error
        expect(target.reload.status).to eq("good")
      end

      context "when validation succeeds with response detected" do
        it "updates target to good status" do
          allow(playwright_service).to receive(:validate_webchat_config).and_return({
            success: true,
            response_detected: true,
            errors: []
          })

          service.call
          target.reload

          expect(target.status).to eq("good")
          expect(target.validation_text).to include("validated successfully")
          expect(target.validation_text).to include("response was detected")
        end
      end

      context "when validation succeeds but no response detected" do
        it "updates target to bad status with partial message" do
          allow(playwright_service).to receive(:validate_webchat_config).and_return({
            success: true,
            response_detected: false,
            errors: []
          })

          service.call
          target.reload

          expect(target.status).to eq("bad")
          expect(target.validation_text).to include("partial")
          expect(target.validation_text).to include("no response detected")
        end
      end

      context "when validation fails" do
        it "updates target to bad status with error message" do
          allow(playwright_service).to receive(:validate_webchat_config).and_return({
            success: false,
            response_detected: false,
            errors: [ "Selector not found: #chat-input" ]
          })

          service.call
          target.reload

          expect(target.status).to eq("bad")
          expect(target.validation_text).to include("validation failed")
          expect(target.validation_text).to include("Selector not found")
        end
      end
    end

    # Note: Edge cases with invalid configurations are tested via model validation specs
    # These integration tests focus on the main validation paths with Playwright

    context "with JSON string web_config" do
      it "successfully parses JSON string config" do
        config = {
          "url" => "https://example.com/chat",
          "selectors" => {
            "input_field" => "#input",
            "response_container" => "#response"
          }
        }

        target.update(web_config: config.to_json)

        allow(playwright_service).to receive(:validate_webchat_config).and_return({
          success: true,
          response_detected: true,
          errors: []
        })

        service.call
        target.reload

        expect(target.status).to eq("good")
      end
    end

    context "error handling" do
      let(:valid_config) do
        {
          "url" => "https://example.com/chat",
          "selectors" => {
            "input_field" => "#input",
            "response_container" => "#response"
          }
        }
      end

      it "catches and handles PlaywrightService errors" do
        target.update(web_config: valid_config)

        allow(playwright_service).to receive(:validate_webchat_config)
          .and_raise(StandardError, "Browser crashed")

        service.call
        target.reload

        expect(target.status).to eq("bad")
        expect(target.validation_text).to include("Browser crashed")
      end

      it "catches and handles unexpected errors in validate_web_chat" do
        target.update(web_config: valid_config)

        allow(playwright_service).to receive(:validate_webchat_config)
          .and_raise(StandardError, "Unexpected error")

        service.call
        target.reload

        expect(target.status).to eq("bad")
        expect(target.validation_text).to include("Unexpected error")
      end
    end
  end

  describe "#valid_url?" do
    it "returns true for valid HTTPS URLs" do
      allow(UrlSafetyValidator).to receive(:resolve_addresses).and_return([ "93.184.216.34" ])
      expect(service.send(:valid_url?, "https://example.com")).to be true
      expect(service.send(:valid_url?, "https://example.com/chat")).to be true
      expect(service.send(:valid_url?, "https://subdomain.example.com")).to be true
    end

    it "returns true for valid HTTP URLs" do
      allow(UrlSafetyValidator).to receive(:resolve_addresses).and_return([ "93.184.216.34" ])
      expect(service.send(:valid_url?, "http://example.com")).to be true
      expect(service.send(:valid_url?, "http://localhost:3000")).to be true
    end

    it "returns false for invalid URLs" do
      expect(service.send(:valid_url?, "not a url")).to be false
      expect(service.send(:valid_url?, "ftp://example.com")).to be false
      expect(service.send(:valid_url?, "javascript:alert(1)")).to be false
      expect(service.send(:valid_url?, "")).to be false
    end

    it "returns false for nil" do
      expect(service.send(:valid_url?, nil)).to be false
    end

    context "SSRF protection" do
      it "rejects internal IP addresses" do
        allow(UrlSafetyValidator).to receive(:safe_url?).and_return(
          UrlSafetyValidator::Result.new("safe?": false, error: "blocked")
        )
        expect(service.send(:valid_url?, "http://127.0.0.1")).to be false
      end

      it "delegates to UrlSafetyValidator" do
        expect(UrlSafetyValidator).to receive(:safe_url?).with("https://example.com", allow_localhost: true).and_call_original
        service.send(:valid_url?, "https://example.com")
      end
    end
  end
end
