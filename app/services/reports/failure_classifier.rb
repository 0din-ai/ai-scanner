# frozen_string_literal: true

module Reports
  class FailureClassifier
    Result = Struct.new(:code, :message, :details, keyword_init: true) do
      def failed?
        code.present?
      end

      def provider_failure?
        code.to_s.start_with?("provider_")
      end
    end

    OPENROUTER = "OpenRouter"
    OTARI = "Otari"
    POLICY_BLOCK_PATTERN = /OtariPolicyBlock: provider_policy_block status_code=(\d+) code=([A-Za-z0-9_-]+) request_id=([^ ]*) error=(.*)/i.freeze
    POLICY_BLOCK_MESSAGE = "Otari marked this target unavailable because of a provider policy block. Contact the provider before revalidating or rerunning the scan.".freeze
    EMPTY_RESULT = Result.new(code: nil, message: nil, details: {}).freeze

    STATUS_CODE_PATTERN = /
      status_code\s*[=:]\s*(\d{3}) |
      status\s*[=:]\s*(\d{3})
    /ix
    PROVIDER_FAILURE_STATUS_CODES = ([ 401, 402, 403, 404, 422, 429 ] + (500..599).to_a).freeze
    MESSAGE_PATTERNS = [
      /"message"\s*:\s*"([^"]+)"/i,
      /message\s*[=:]\s*["']?([^"'
}]+)/i,
      /error\s*[=:]\s*["']?([^"'
}]+)/i
    ].freeze
    # garak logs one "Garak scan completed ... Exit code: N" line per attempt, and the
    # run log is appended across same-day retries (deterministic per-report path opened
    # in append mode), so only the LAST line reflects the current run. Judge a clean
    # completion from that last exit code, not any matching line in the accumulated log.
    GARAK_COMPLETION_PATTERN = /Garak scan completed.*?Exit code:\s*(\d+)/i

    def self.cleanly_completed?(logs)
      last_exit = logs.to_s.scan(GARAK_COMPLETION_PATTERN).last
      last_exit.present? && last_exit.first == "0"
    end

    HTTP_PROVIDER_STATUS_PATTERN = /HTTP\/\d(?:\.\d)?\s+(401|402|403|404|422|429|5\d{2})/i
    HTTP_PROVIDER_HINT_PATTERN = /openrouter|otari|provider|deprecated|no endpoints|credits?|rate limit/i
    AUTH_HINT_PATTERN = /unauthori[sz]ed|invalid api key|authentication|credentials/i
    REJECTED_REQUEST_HINT_PATTERN = /rejected request|request rejected|invalid request/i
    TARGET_VALIDATION_HINT_PATTERN = /target validation failed|no responses received|0\/\d+\s+attempts passed/i
    MODEL_UNAVAILABLE_HINT_PATTERN = /
      deprecated|model\ .*unavailable|unavailable\ .*model|no\ endpoints|model\ .*not\ found|not\ found\ .*model
    /ix
    SECRET_PATTERNS = [
      [ /(Bearer\s+)[A-Za-z0-9._~+\-\/=]+/i, '\1[REDACTED]' ],
      [ /((?:Basic|Digest|NTLM|Negotiate)\s+)[A-Za-z0-9._~+\-\/=]+/i, '\1[REDACTED]' ],
      [ /((?:api[_-]?key|token|secret|password|authorization)["']?\s*[=:]\s*)["']?[^"'\s,}]+/i, '\1[REDACTED]' ],
      [ /\bsk-(?:or-v1-)?[A-Za-z0-9_\-]{8,}\b/i, "[REDACTED]" ],
      [ /((?:set-)?cookie\s*:\s*)[^\n]+/i, '\1[REDACTED]' ],
      [ /(x-[\w-]*(?:key|token|auth|secret|cookie)[\w-]*\s*[=:]\s*)["']?[^"'\s,}]+/i, '\1[REDACTED]' ]
    ].freeze

    def initialize(report, logs: nil, exit_code: nil, exception_message: nil)
      @report = report
      @logs = logs
      @exit_code = exit_code
      @exception_message = exception_message
    end

    def self.sanitize_text(text)
      return text if text.blank?

      SECRET_PATTERNS.reduce(text.to_s) do |sanitized, (pattern, replacement)|
        sanitized.gsub(pattern, replacement)
      end
    end

    def call
      return EMPTY_RESULT if evidence_text.blank? && exit_code.blank?
      policy_block = classify_policy_block
      return policy_block if policy_block.failed?

      provider_result = classify_provider_failure
      return provider_result if provider_result.failed?

      target_result = classify_target_validation_failure
      return target_result if target_result.failed?

      runtime_result = classify_runtime_failure
      return runtime_result if runtime_result.failed?

      EMPTY_RESULT
    end

    private

    attr_reader :report, :logs, :exit_code, :exception_message
    def classify_policy_block
      match = evidence_text.match(POLICY_BLOCK_PATTERN)
      return EMPTY_RESULT unless match

      Result.new(
        code: "provider_policy_block",
        message: POLICY_BLOCK_MESSAGE,
        details: sanitize_value({
          "provider" => OTARI,
          "gateway" => "otari",
          "status_code" => match[1].to_i,
          "block_code" => match[2],
          "request_id" => match[3].presence,
          "provider_error" => match[4].presence
        }.compact)
      )
    end

    def classify_provider_failure
      return EMPTY_RESULT unless provider_error_evidence?

      case status_code
      when 404
        return build_result("provider_model_unavailable") if model_unavailable_text?
      when 402
        return build_result("provider_payment_required")
      when 401
        return build_result("provider_auth_failed")
      when 403
        return build_result("provider_rejected_request")
      when 422
        return build_result("provider_rejected_request")
      when 429
        return build_result("provider_rate_limited")
      when 500..599
        return build_result("provider_service_unavailable")
      end

      return build_result("provider_payment_required") if evidence_text.match?(/payment|billing|credits?/i)
      return build_result("provider_auth_failed") if evidence_text.match?(AUTH_HINT_PATTERN)
      return build_result("provider_rejected_request") if evidence_text.match?(REJECTED_REQUEST_HINT_PATTERN)
      return build_result("provider_rate_limited") if evidence_text.match?(/rate limit|too many requests/i)
      return build_result("provider_model_unavailable") if model_unavailable_text?

      EMPTY_RESULT
    end

    def classify_target_validation_failure
      return EMPTY_RESULT unless evidence_text.match?(TARGET_VALIDATION_HINT_PATTERN)

      build_result("target_validation_failed")
    end

    def classify_runtime_failure
      # A traceback/exception that surfaces after a clean garak completion (exit 0)
      # is post-scan noise (e.g. garak's report-digest builder), not a runtime failure.
      return EMPTY_RESULT if self.class.cleanly_completed?(evidence_text) && !exit_code.to_i.positive?

      # A nonzero last completion marker is an authoritative current-run failure even
      # without a traceback: db_notifier appends the real garak exit code to the logs,
      # so an exit != 0 means garak itself signalled failure (the digest crash exits 0,
      # so this never re-fails a cleanly-completed scan).
      return EMPTY_RESULT unless exit_code.to_i.positive? || nonzero_garak_exit? ||
        exception_message.present? ||
        evidence_text.match?(/traceback|exception|runtimeerror|garak .*failed|non[- ]?zero/i)

      build_result("garak_runtime_error")
    end

    def build_result(code)
      Result.new(
        code: code,
        message: message_for(code),
        details: compact_details
      )
    end

    def compact_details
      raw_details = {
        "provider" => provider,
        "gateway" => ("otari" if provider == OTARI),
        "model" => model,
        "status_code" => status_code,
        "provider_message" => provider_message,
        "exit_code" => effective_exit_code,
        "exception_message" => exception_message
      }

      sanitize_value(raw_details.compact)
    end

    def message_for(code)
      case code
      when "provider_model_unavailable"
        message = "#{provider || 'The provider'} rejected configured model "           "#{model || 'the selected model'} as unavailable or deprecated."
        message += " Provider message: #{provider_message}." if provider_message.present?
        message += " Update the target model, revalidate the target, then rerun the scan."
        sanitize_text(message)
      when "provider_payment_required"
        sanitize_text(
          "#{provider || 'The provider'} rejected the scan because billing or credits are required. "           "Check provider billing or credits, then rerun the scan."
        )
      when "provider_auth_failed"
        sanitize_text(
          "#{provider || 'The provider'} authentication failed. Check the target API credentials, "           "revalidate the target, then rerun the scan."
        )
      when "provider_rejected_request"
        sanitize_text(
          "#{provider || 'The provider'} rejected the scan request. Review the target model/configuration, "           "revalidate the target, then rerun the scan."
        )
      when "provider_rate_limited"
        sanitize_text(
          "#{provider || 'The provider'} rate limit was reached. Wait or reduce scan concurrency, "           "then rerun the scan."
        )
      when "provider_service_unavailable"
        sanitize_text(
          "#{provider || 'The provider'} is temporarily unavailable or returned an upstream error. "           "Wait for the provider to recover, revalidate the target, then rerun the scan."
        )
      when "target_validation_failed"
        sanitize_text(
          "Target validation failed. Fix the target configuration, revalidate the target, "           "then rerun the scan."
        )
      when "garak_runtime_error"
        sanitize_text(
          "The scan runtime failed before results could be completed. Review the target configuration, "           "then rerun the scan."
        )
      end
    end

    def provider_error_evidence?
      terminal_provider_error? || configured_provider_error? || http_provider_error?
    end

    def terminal_provider_error?
      evidence_text.match?(/terminal API status error|provider .*status error/i)
    end

    def configured_provider_error?
      provider.present? && terminal_provider_error? && PROVIDER_FAILURE_STATUS_CODES.include?(status_code)
    end

    def http_provider_error?
      return false if successful_garak_completion?

      evidence_text.match?(HTTP_PROVIDER_STATUS_PATTERN) && evidence_text.match?(HTTP_PROVIDER_HINT_PATTERN)
    end

    def successful_garak_completion?
      self.class.cleanly_completed?(evidence_text)
    end

    # Exit code from the LAST "Garak scan completed ... Exit code: N" marker in the
    # accumulated log, or nil when no marker is present. Same parse as cleanly_completed?
    # (last match wins across same-day retry logs).
    def last_marker_exit_code
      return @last_marker_exit_code if defined?(@last_marker_exit_code)

      match = evidence_text.scan(GARAK_COMPLETION_PATTERN).last
      @last_marker_exit_code = match&.first&.to_i
    end

    def nonzero_garak_exit?
      last_marker_exit_code.to_i.positive?
    end

    # The explicit constructor exit code is authoritative; otherwise fall back to a
    # nonzero marker exit so the persisted failure detail matches the classification.
    def effective_exit_code
      exit_code || (nonzero_garak_exit? ? last_marker_exit_code : nil)
    end

    def model_unavailable_text?
      evidence_text.match?(MODEL_UNAVAILABLE_HINT_PATTERN)
    end

    def evidence_text
      @evidence_text ||= [ logs, exception_message ].compact.join("
")
    end

    def status_code
      @status_code ||= explicit_status_code || http_provider_status_code
    end

    def explicit_status_code
      match = evidence_text.match(STATUS_CODE_PATTERN)
      match&.captures&.compact&.first&.to_i
    end

    def http_provider_status_code
      match = evidence_text.match(HTTP_PROVIDER_STATUS_PATTERN)
      match&.[](1)&.to_i
    end

    def provider
      @provider ||= if report.target&.model_type == "OtariGenerator"
        OTARI
      elsif evidence_text.match?(/openrouter/i) || report.target&.model_type.to_s.match?(/openrouter/i)
        OPENROUTER
      end
    end

    def model
      @model ||= begin
        configured_model = report.target&.model.presence
        configured_model || evidence_text[/[a-z0-9][a-z0-9._-]+\/[a-z0-9][a-z0-9._-]+/i]
      end
    end

    def provider_message
      @provider_message ||= begin
        message = MESSAGE_PATTERNS.filter_map { |pattern| evidence_text.match(pattern)&.[](1) }.first
        sanitize_text(message&.strip)
      end
    end

    def sanitize_value(value)
      case value
      when Hash
        value.transform_values { |nested| sanitize_value(nested) }
      when Array
        value.map { |nested| sanitize_value(nested) }
      when String
        sanitize_text(value)
      else
        value
      end
    end

    def sanitize_text(text)
      self.class.sanitize_text(text)
    end
  end
end
