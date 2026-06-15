require "rails_helper"

RSpec.describe AutoDetectWebchatSelectors do
  let(:url) { "https://example.com/chat" }
  let(:session_id) { "test-session-123" }
  let(:service) { described_class.new(url, session_id: session_id) }
  let(:playwright_service) { instance_double(BrowserAutomation::PlaywrightService) }
  let(:detection_service) { instance_double(WebchatSelectorDetectionService) }
  let(:action_cable_server) { instance_double(ActionCable::Server::Base) }

  let(:page_data) do
    {
      "html" => "<html><body><div class='chat'>...</div></body></html>",
      "screenshot" => "base64_encoded_image"
    }
  end

  let(:detected_selectors) do
    {
      input_field: "#chat-input",
      send_button: "#send-btn",
      response_container: ".chat-messages"
    }
  end

  before do
    allow(BrowserAutomation::PlaywrightService).to receive(:instance).and_return(playwright_service)
    allow(WebchatSelectorDetectionService).to receive(:new).and_return(detection_service)
    allow(ActionCable).to receive(:server).and_return(action_cable_server)
    allow(action_cable_server).to receive(:broadcast)
  end

  describe "#initialize" do
    it "sets url and session_id" do
      expect(service.url).to eq(url)
      expect(service.session_id).to eq(session_id)
    end

    it "works without session_id" do
      service_without_session = described_class.new(url)
      expect(service_without_session.session_id).to be_nil
    end
  end

  describe "#call" do
    context "when detection succeeds on first attempt" do
      before do
        allow(playwright_service).to receive(:extract_page_structure).and_return(page_data)
        allow(detection_service).to receive(:detect_selectors).and_return({ selectors: detected_selectors })
        allow(playwright_service).to receive(:validate_webchat_config).and_return({
          success: true,
          response_detected: true,
          errors: []
        })
      end

      it "returns selectors and screenshot" do
        result = service.call

        expect(result).to be_a(Hash)
        expect(result[:selectors]).to eq(detected_selectors)
        expect(result[:screenshot]).to eq("base64_encoded_image")
      end

      it "broadcasts progress updates" do
        expect(action_cable_server).to receive(:broadcast).with("auto_detect_#{session_id}", hash_including(
          type: "progress",
          step: "launching"
        ))
        expect(action_cable_server).to receive(:broadcast).with("auto_detect_#{session_id}", hash_including(
          type: "progress",
          step: "page_loaded"
        ))
        expect(action_cable_server).to receive(:broadcast).with("auto_detect_#{session_id}", hash_including(
          type: "complete",
          step: "success"
        ))

        service.call
      end

      it "sends cleanup signal" do
        expect(action_cable_server).to receive(:broadcast).with("auto_detect_#{session_id}", hash_including(
          type: "cleanup"
        ))

        service.call
      end
    end

    context "when detection succeeds after retries" do
      before do
        allow(playwright_service).to receive(:extract_page_structure).and_return(page_data)
      end

      it "succeeds on second attempt" do
        allow(detection_service).to receive(:detect_selectors)
          .with(attempt: 1, previous_errors: [])
          .and_return({ selectors: detected_selectors })

        allow(playwright_service).to receive(:validate_webchat_config)
          .and_return(
            { success: true, response_detected: false, errors: [ "Selector not found" ] },
            { success: true, response_detected: true, errors: [] }
          )

        allow(detection_service).to receive(:detect_selectors)
          .with(attempt: 2, previous_errors: [ "Selector not found" ])
          .and_return({ selectors: detected_selectors })

        result = service.call

        expect(result).to be_a(Hash)
        expect(result[:selectors]).to eq(detected_selectors)
      end

      it "broadcasts retry warnings" do
        allow(detection_service).to receive(:detect_selectors).and_return({ selectors: detected_selectors })
        allow(playwright_service).to receive(:validate_webchat_config)
          .and_return(
            { success: false, response_detected: false, errors: [ "Error 1" ] },
            { success: true, response_detected: true, errors: [] }
          )

        expect(action_cable_server).to receive(:broadcast).with("auto_detect_#{session_id}", hash_including(
          type: "warning",
          step: "retry"
        ))

        service.call
      end
    end

    context "when detection fails after max attempts" do
      before do
        allow(playwright_service).to receive(:extract_page_structure).and_return(page_data)
        allow(detection_service).to receive(:detect_selectors).and_return({ selectors: detected_selectors })
        allow(playwright_service).to receive(:validate_webchat_config).and_return({
          success: false,
          response_detected: false,
          errors: [ "Selector not found" ]
        })
      end

      it "returns nil" do
        result = service.call
        expect(result).to be_nil
      end

      it "broadcasts error message with max attempts context" do
        expect(action_cable_server).to receive(:broadcast).with("auto_detect_#{session_id}", hash_including(
          type: "error",
          message: include("failed after #{described_class::MAX_DETECTION_ATTEMPTS} attempts")
        ))

        service.call
      end

      it "sends cleanup signal" do
        expect(action_cable_server).to receive(:broadcast).with("auto_detect_#{session_id}", hash_including(
          type: "cleanup"
        ))

        service.call
      end

      it "attempts detection MAX_DETECTION_ATTEMPTS times" do
        expect(detection_service).to receive(:detect_selectors).exactly(described_class::MAX_DETECTION_ATTEMPTS).times
        service.call
      end
    end

    context "when page load fails" do
      before do
        allow(playwright_service).to receive(:extract_page_structure).and_return(nil)
      end

      it "returns nil" do
        result = service.call
        expect(result).to be_nil
      end

      it "broadcasts page load error" do
        expect(action_cable_server).to receive(:broadcast).with("auto_detect_#{session_id}", hash_including(
          type: "error",
          message: include("Unable to load the webpage")
        ))

        service.call
      end

      it "sends cleanup signal" do
        expect(action_cable_server).to receive(:broadcast).with("auto_detect_#{session_id}", hash_including(
          type: "cleanup"
        ))

        service.call
      end
    end

    context "when detection service returns invalid result" do
      before do
        allow(playwright_service).to receive(:extract_page_structure).and_return(page_data)
        allow(detection_service).to receive(:detect_selectors).and_return(nil)
      end

      it "returns nil" do
        result = service.call
        expect(result).to be_nil
      end

      it "broadcasts exception error" do
        expect(action_cable_server).to receive(:broadcast).with("auto_detect_#{session_id}", hash_including(
          type: "error",
          message: include("unexpected error")
        ))

        service.call
      end
    end

    context "when exception is raised" do
      before do
        allow(playwright_service).to receive(:extract_page_structure).and_raise(StandardError, "Browser crash")
      end

      it "returns nil" do
        result = service.call
        expect(result).to be_nil
      end

      it "broadcasts exception error" do
        expect(action_cable_server).to receive(:broadcast).with("auto_detect_#{session_id}", hash_including(
          type: "error",
          message: include("unexpected error")
        ))

        service.call
      end

      it "sends cleanup signal" do
        expect(action_cable_server).to receive(:broadcast).with("auto_detect_#{session_id}", hash_including(
          type: "cleanup"
        ))

        service.call
      end
    end

    context "without session_id" do
      let(:service_without_session) { described_class.new(url) }

      before do
        allow(playwright_service).to receive(:extract_page_structure).and_return(page_data)
        allow(detection_service).to receive(:detect_selectors).and_return({ selectors: detected_selectors })
        allow(playwright_service).to receive(:validate_webchat_config).and_return({
          success: true,
          response_detected: true,
          errors: []
        })
      end

      it "does not broadcast" do
        expect(action_cable_server).not_to receive(:broadcast)
        service_without_session.call
      end

      it "still returns results" do
        result = service_without_session.call
        expect(result[:selectors]).to eq(detected_selectors)
      end
    end
  end

  describe "#message_type_for_step" do
    it "returns 'progress' for progress steps" do
      expect(service.send(:message_type_for_step, :launching)).to eq("progress")
      expect(service.send(:message_type_for_step, :page_loaded)).to eq("progress")
      expect(service.send(:message_type_for_step, :analyzing)).to eq("progress")
      expect(service.send(:message_type_for_step, :detecting)).to eq("progress")
      expect(service.send(:message_type_for_step, :validating)).to eq("progress")
    end

    it "returns 'warning' for warning steps" do
      expect(service.send(:message_type_for_step, :retry)).to eq("warning")
    end

    it "returns 'complete' for success steps" do
      expect(service.send(:message_type_for_step, :success)).to eq("complete")
    end

    it "returns 'error' for error steps" do
      expect(service.send(:message_type_for_step, :error)).to eq("error")
    end

    it "returns 'progress' for unknown steps" do
      expect(service.send(:message_type_for_step, :unknown)).to eq("progress")
    end
  end

  describe "#build_error_message" do
    it "builds max_attempts_exceeded message" do
      message = service.send(:build_error_message, :max_attempts_exceeded)
      expect(message).to include("failed after #{described_class::MAX_DETECTION_ATTEMPTS} attempts")
      expect(message).to include("Try configuring selectors manually")
    end

    it "builds page_load_failed message" do
      message = service.send(:build_error_message, :page_load_failed)
      expect(message).to include("Unable to load the webpage")
      expect(message).to include("#{described_class::PAGE_EXTRACTION_WAIT_MS / 1000} seconds")
    end

    it "builds exception message" do
      message = service.send(:build_error_message, :exception)
      expect(message).to include("unexpected error")
      expect(message).to include("Try again")
    end

    it "builds default message for unknown context" do
      message = service.send(:build_error_message, :unknown)
      expect(message).to include("Detection failed")
    end
  end

  describe "auth forwarding" do
    let(:auth) { { "headers" => { "Authorization" => "Bearer x" } } }

    before do
      allow(detection_service).to receive(:detect_selectors).and_return(
        selectors: { "input_field" => "#i", "response_container" => "#r", "response_text" => "" }
      )
    end

    it "forwards auth to extract_page_structure and validate_webchat_config" do
      expect(playwright_service).to receive(:extract_page_structure)
        .with(url, hash_including(auth: auth)).and_return({ "screenshot" => "x" })
      expect(playwright_service).to receive(:validate_webchat_config) do |_url, cfg|
        expect(cfg[:auth]).to eq(auth)
        { success: true, response_detected: true, errors: [] }
      end

      described_class.new(url, session_id: nil, auth: auth).call
    end

    it "sanitizes secrets from auto-detect failure logs" do
      allow(playwright_service).to receive(:extract_page_structure).and_return(page_data)
      allow(detection_service).to receive(:detect_selectors).and_return(
        selectors: { "input_field" => "#i", "response_container" => "#r", "response_text" => "" }
      )
      allow(playwright_service).to receive(:validate_webchat_config).and_return(
        success: false, response_detected: false, errors: [ "browser error Bearer secret-token-123" ]
      )

      logged = []
      allow(Rails.logger).to receive(:warn) { |m| logged << m }
      allow(Rails.logger).to receive(:error) { |m| logged << m }
      allow(Rails.logger).to receive(:info)

      described_class.new(url, session_id: nil, auth: { "headers" => { "Authorization" => "Bearer secret-token-123" } }).call

      expect(logged.join("\n")).not_to include("secret-token-123")
      expect(logged.join("\n")).to include("[REDACTED]")
    end
  end

  describe "#progress_for_step" do
    it "returns correct progress for static steps" do
      expect(service.send(:progress_for_step, :launching)).to eq(10)
      expect(service.send(:progress_for_step, :page_loaded)).to eq(20)
      expect(service.send(:progress_for_step, :analyzing)).to eq(30)
      expect(service.send(:progress_for_step, :success)).to eq(100)
    end

    it "calculates progress for detecting based on attempt" do
      expect(service.send(:progress_for_step, :detecting, 1)).to eq(45)
      expect(service.send(:progress_for_step, :detecting, 2)).to eq(60)
      expect(service.send(:progress_for_step, :detecting, 3)).to eq(75)
    end

    it "calculates progress for validating based on attempt" do
      expect(service.send(:progress_for_step, :validating, 1)).to eq(55)
      expect(service.send(:progress_for_step, :validating, 2)).to eq(70)
      expect(service.send(:progress_for_step, :validating, 3)).to eq(85)
    end

    it "calculates progress for retry based on attempt" do
      expect(service.send(:progress_for_step, :retry, 1)).to eq(50)
      expect(service.send(:progress_for_step, :retry, 2)).to eq(65)
      expect(service.send(:progress_for_step, :retry, 3)).to eq(80)
    end
  end
end
