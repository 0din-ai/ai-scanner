require "digest"

class ValidateWebChatTarget
  LOGS_PATH = Rails.root.join("storage", "logs").expand_path
  CONFIG_PATH = Rails.root.join("storage", "config").expand_path
  VALIDATION_REPORTS_PATH = Rails.root.join("..", "home", "rails", ".local", "share", "garak", "garak_runs").expand_path

  attr_reader :target

  def initialize(target)
    @target = target
  end

  def call
    target.update(status: :validating)

    begin
      validate_web_chat
    rescue StandardError => e
      Rails.logger.error("Validation failed for target #{target.id}: #{e.message}")
      target.update(status: :bad, validation_text: "Validation failed: #{e.message}")
    end
  end

  private

  def validate_web_chat
    config = target.web_config.is_a?(String) ? JSON.parse(target.web_config) : target.web_config

    if config.blank? || config["url"].blank?
      target.update(status: :bad, validation_text: "Web chat configuration is missing or incomplete")
      return
    end

    url = config["url"]
    selectors = config["selectors"] || {}

    unless valid_url?(url)
      target.update(status: :bad, validation_text: "Web chat validation failed: Invalid URL format")
      return
    end

    # Selectors are required for validation
    if selectors.blank? || selectors["input_field"].blank? || selectors["response_container"].blank?
      target.update(
        status: :bad,
        validation_text: "Web chat validation failed: Selectors are missing. " \
                        "Please provide selectors manually or run auto-detection first using AutoDetectWebchatSelectors."
      )
      return
    end

    perform_interaction_test(url, selectors)
  rescue StandardError => e
    target.update(
      status: :bad,
      validation_text: "Web chat validation error: #{e.message}"
    )
  end

  def perform_interaction_test(url, selectors)
    service = BrowserAutomation::PlaywrightService.instance

    # Build config for PlaywrightService (Phase 2 smart waits)
    config = {
      selectors: {
        input_field: selectors["input_field"],
        send_button: selectors["send_button"],
        response_container: selectors["response_container"]
      },
      wait_times: {
        page_load: 30000,
        response: 5000
      }
    }

    # Use existing Phase 2 validation (smart waits, 100% success rate)
    result = service.validate_webchat_config(url, config)

    if result[:success] && result[:response_detected]
      target.update(
        status: :good,
        validation_text: "Web chat configuration validated successfully. " \
                        "Test message was sent and response was detected. " \
                        "Selectors: #{selectors.to_json}"
      )
    elsif result[:success] && !result[:response_detected]
      target.update(
        status: :bad,
        validation_text: "Web chat validation partial: Selectors found but no response detected. " \
                        "The chat may require login or have slow response times."
      )
    else
      target.update(
        status: :bad,
        validation_text: "Web chat validation failed: #{result[:errors].join(', ')}. " \
                        "The selectors may be incorrect or the chat interface may have changed."
      )
    end
  rescue StandardError => e
    Rails.logger.error "Interaction test error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    target.update(
      status: :bad,
      validation_text: "Error testing web chat interaction: #{e.message}"
    )
  end

  def valid_url?(url)
    result = UrlSafetyValidator.safe_url?(url, allow_localhost: UrlSafetyValidator.allow_localhost?)
    result.safe?
  end
end
