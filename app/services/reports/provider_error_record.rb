# frozen_string_literal: true

module Reports
  # The structured record a garak generator logs right before it raises a terminal
  # ProviderError: one line, `PROVIDER_ERROR {json}`, written by the OpenRouter
  # generator (script/garak_plugins/openrouter.py). The generator classifies the
  # provider's error object once; Rails reads the category as data and never
  # re-derives it from the upstream message, so a provider rewording its error
  # text cannot change the failure code.
  #
  # The upstream message is kept (secret-redacted) for failure_details and debug
  # output only. Customer-facing text is built from category, provider and model.
  class ProviderErrorRecord
    LINE_PATTERN = /PROVIDER_ERROR (\{.*\})\s*$/
    # Each run_garak.py invocation logs this before running probes. Logs are
    # appended across retries, so only text after the last start belongs to the
    # current run.
    ATTEMPT_START_PATTERN = /^.*Starting garak scan - Report: .*$/

    CATEGORY_FAILURE_CODES = {
      "identity_policy_block" => "provider_policy_block",
      "auth_failed" => "provider_auth_failed",
      "billing" => "provider_payment_required",
      "model_unavailable" => "provider_model_unavailable",
      "rejected_request" => "provider_rejected_request",
      "rate_limited" => "provider_rate_limited",
      "upstream_unavailable" => "provider_service_unavailable",
      "provider_error" => "provider_error"
    }.freeze

    # The generator logs these, then raises the matching retryable openai error
    # instead of a terminal ProviderError, so the record may describe a call a
    # caller retried past. Every other category precedes a terminal ProviderError.
    TRANSIENT_CATEGORIES = %w[rate_limited upstream_unavailable].freeze

    MODEL_PATTERN = %r{\A[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._:-]*\z}i
    PROVIDER_PATTERN = /\A[A-Za-z][A-Za-z0-9 ._-]{0,40}\z/
    CODE_PATTERN = /\A[a-z0-9_.-]{1,64}\z/i
    REQUEST_ID_PATTERN = /\A(?:(?:req|gen|chatcmpl)[-_][A-Za-z0-9_-]{1,120}|\h{8}(?:-\h{4}){3}-\h{12})\z/
    UNSAFE_ID_PATTERN = /sk[-_]|api[-_]?key|token|secret|password|bearer/i
    MESSAGE_LIMIT = 300

    # The final line of a Python traceback, "pkg.module.ClassName: message", at the
    # start of a line. backoff's "Backing off ... (openai.InternalServerError: ...)"
    # is logged on EVERY retry, including recovered ones, and never starts a line.
    # ProviderRetryExhausted is named for what happened, not "...Error", so it is
    # listed explicitly or the rule below would never see it.
    EXCEPTION_LINE_PATTERN = /\A(?:[A-Za-z_]\w*\.)*(?:[A-Za-z_]\w*(?:Error|Exception)|ProviderRetryExhausted)(?::|\s*\z)/
    # What the generator raises once its bounded retry of a transient failure gives
    # up (ProviderRetryExhausted), plus the openai classes older generators raised.
    RETRY_EXHAUSTED_PATTERN = /\A(?:(?:[A-Za-z_]\w*\.)*ProviderRetryExhausted|openai\.(?:RateLimitError|InternalServerError))\b/

    attr_reader :category, :provider, :model, :http_status, :provider_status,
      :provider_code, :provider_error_type, :request_id, :message
    attr_accessor :trailing_text

    # The last well-formed record in the current run's slice of +logs+, or nil.
    # terminal_only skips retried transient records, which never ended a run alone.
    def self.last_in(logs, terminal_only: false)
      lines = current_run(logs.to_s).lines
      lines.each_index.reverse_each do |index|
        record = parse_line(lines[index])
        next unless record && (!terminal_only || record.terminal?)

        record.trailing_text = lines[(index + 1)..].join
        return record
      end
      nil
    end

    def self.terminal_category?(category)
      CATEGORY_FAILURE_CODES.key?(category) && !TRANSIENT_CATEGORIES.include?(category)
    end

    def self.current_run(text)
      starts = text.to_enum(:scan, ATTEMPT_START_PATTERN).map { Regexp.last_match.begin(0) }
      starts.any? ? text[starts.last..] : text
    end

    def self.parse_line(line)
      json = line.match(LINE_PATTERN)&.[](1)
      return unless json

      data = JSON.parse(json)
      return unless data.is_a?(Hash) && data["v"] == 1 && data["category"].is_a?(String)

      new(data)
    rescue JSON::ParserError
      nil
    end

    def initialize(data)
      @category = CATEGORY_FAILURE_CODES.key?(data["category"]) ? data["category"] : "provider_error"
      @provider = string_matching(data["provider"], PROVIDER_PATTERN)
      @model = string_matching(data["model"], MODEL_PATTERN)
      @http_status = status_integer(data["http_status"])
      @provider_status = status_integer(data["provider_status"])
      @provider_code = string_matching(data["provider_code"], CODE_PATTERN)
      @provider_error_type = string_matching(data["provider_error_type"], CODE_PATTERN)
      @request_id = safe_request_id(data["request_id"])
      @message = safe_message(decode_hex(data["message_hex"]) || data["message"])
    end

    def terminal?
      !TRANSIENT_CATEGORIES.include?(category)
    end

    # The one rule every caller uses: a terminal record always explains a failed
    # run; a transient one only when it is what ended the run.
    def explains_failure?
      terminal? || ended_run?
    end

    # Whether this transient record is what ended the run: the last exception
    # raised after it is garak giving up on that retry, or nothing raised at all.
    # Any other final exception means the retry recovered and something else failed.
    def ended_run?
      last_exception = trailing_text.to_s.lines.map(&:strip).reverse.find { |l| l.match?(EXCEPTION_LINE_PATTERN) }
      last_exception.nil? || last_exception.match?(RETRY_EXHAUSTED_PATTERN)
    end

    def failure_code
      CATEGORY_FAILURE_CODES.fetch(category)
    end

    # Customer-facing sentence. Never includes the upstream message: it is
    # provider free text that can echo the probe prompt.
    def user_message
      who = provider || "The provider"
      what = model || "the configured model"
      sentence = case category
      when "identity_policy_block"
        "#{who} refused #{what}: the upstream provider blocked this account for a previous policy violation. " \
          "Other models on the same key may still work. Contact #{provider || 'the provider'} about this model " \
          "before revalidating the target."
      when "auth_failed"
        "#{who} authentication failed for #{what}. Check the target API credentials, then revalidate the target."
      when "billing"
        "#{who} requires billing or credits before it will serve #{what}. Check the provider account, then revalidate the target."
      when "model_unavailable"
        "#{who} reported #{what} as unavailable. Update the target model, then revalidate the target."
      when "rejected_request"
        "#{who} rejected the request to #{what}. Review the target configuration, then revalidate the target."
      when "rate_limited"
        "#{who} rate limited requests to #{what}. Wait or reduce concurrency, then revalidate the target."
      when "upstream_unavailable"
        "#{who} could not reach an upstream provider for #{what}. Wait for the provider to recover, then revalidate the target."
      else
        "#{who} returned an error instead of a completion for #{what}. Review the target configuration, then revalidate the target."
      end
      sentence += " Request ID: #{request_id}." if request_id
      FailureClassifier.sanitize_text(sentence)
    end

    def details
      {
        "provider" => provider,
        "model" => model,
        "status_code" => http_status,
        "provider_status" => provider_status,
        "provider_category" => category,
        "provider_code" => provider_code,
        "provider_error_type" => provider_error_type,
        "request_id" => request_id,
        "provider_message" => message
      }.compact
    end

    private

    def string_matching(value, pattern)
      value if value.is_a?(String) && value.match?(pattern)
    end

    def status_integer(value)
      value if value.is_a?(Integer) && value.between?(100, 599)
    end

    def safe_request_id(value)
      return unless value.is_a?(String) && value.match?(REQUEST_ID_PATTERN)
      return if value.match?(UNSAFE_ID_PATTERN)

      value
    end

    # The generator hex-encodes the upstream message: RunCommand#sanitize_output
    # regex-redacts captured output before Rails reads it, and a credential or
    # Cookie: substring inside plain JSON text would otherwise corrupt the record.
    # Hex cannot spell any of the keywords those patterns key on.
    def decode_hex(value)
      return unless value.is_a?(String) && value.match?(/\A(?:\h\h)+\z/)

      [ value ].pack("H*").force_encoding(Encoding::UTF_8).scrub
    end

    def safe_message(value)
      return unless value.is_a?(String) && value.present?

      FailureClassifier.sanitize_text(value.gsub(/[[:cntrl:]]+/, " ").squish.truncate(MESSAGE_LIMIT))
    end
  end
end
