# frozen_string_literal: true

# Global, super-admin-only configuration of the LLM judge that re-decides detector
# scores inside a band around the evaluation threshold.
#
# The non-secret values are Metadatum rows written ONLY through
# SettingsService.set_judge_settings! (the generic /metadata CRUD refuses every
# judge_* key). The provider API key is never stored in the database: it is read from
# the deployment environment (JUDGE_API_KEY), the same way the rest of the deployment's
# secrets reach the container, and handed to garak at launch.
module JudgeSettings
  # Raised only by this module's validation, so the Settings page can show the message
  # without also surfacing an unrelated ArgumentError.
  class ValidationError < ArgumentError; end

  KEYS = %w[
    judge_enabled judge_provider judge_model_name judge_band_below judge_band_above
    judge_max_calls_per_scan judge_max_provider_errors judge_timeout_seconds judge_concurrency
  ].freeze

  # Fixed providers only; the plugin owns their base URLs. There is deliberately no
  # custom-endpoint provider: a user-supplied URL would be an SSRF surface.
  PROVIDERS = %w[openrouter openai nim].freeze
  PROMPT_VERSION = "v1"
  KEY_ENV = "JUDGE_API_KEY"

  DEFAULTS = {
    "judge_enabled" => "false", "judge_provider" => "openrouter", "judge_model_name" => "",
    "judge_band_below" => "0.2", "judge_band_above" => "0.2",
    "judge_max_calls_per_scan" => "1000", "judge_max_provider_errors" => "5",
    "judge_timeout_seconds" => "30", "judge_concurrency" => "4"
  }.freeze

  # Mirrors the ranges the plugin enforces; a value outside them would make garak reject
  # the whole configuration and leave every in-band output unjudged.
  INT_RANGES = {
    "judge_max_calls_per_scan" => 1..100_000, "judge_max_provider_errors" => 1..1000,
    "judge_timeout_seconds" => 5..120, "judge_concurrency" => 1..16
  }.freeze

  class << self
    # The stored rows, typed. A stored combination that no longer validates falls back
    # to the defaults (judge off) rather than taking the Settings page down.
    def current
      validate!(stored)
    rescue ValidationError => e
      Rails.logger.warn("JudgeSettings.current fell back to defaults: #{e.message}")
      validate!(DEFAULTS)
    end

    # All rows in ONE statement, so a concurrent save cannot hand a reader half of the
    # old configuration and half of the new. Metadatum is global and plaintext, so pluck
    # bypasses nothing here.
    def stored
      rows = Metadatum.where(key: KEYS).pluck(:key, :value).to_h
      DEFAULTS.merge(rows.slice(*KEYS).compact)
    end

    # Typed hash in KEYS order, or ValidationError naming the failing key. Validated as
    # one unit: enabling with a blank model is rejected even though each row alone is a
    # valid string.
    def validate!(attrs)
      raw = DEFAULTS.merge(attrs.to_h.transform_keys(&:to_s).slice(*KEYS).transform_values { |v| v.to_s.strip })
      typed = {}

      # Exact tokens only: a lenient boolean cast would turn any unknown non-empty string
      # into "enabled".
      fail_on("judge_enabled", "must be true or false") unless %w[true false 1 0].include?(raw["judge_enabled"])
      typed["judge_enabled"] = %w[true 1].include?(raw["judge_enabled"])

      typed["judge_provider"] = raw["judge_provider"]
      fail_on("judge_provider", "must be one of #{PROVIDERS.join(', ')}") unless PROVIDERS.include?(typed["judge_provider"])

      typed["judge_model_name"] = raw["judge_model_name"]
      fail_on("judge_model_name", "is too long") if typed["judge_model_name"].length > 200

      %w[judge_band_below judge_band_above].each do |k|
        f = Float(raw[k], exception: false)
        fail_on(k, "must be a number between 0 and 1") if f.nil? || !f.between?(0.0, 1.0)
        typed[k] = f
      end

      INT_RANGES.each do |k, range|
        i = Integer(raw[k], 10, exception: false)
        fail_on(k, "must be an integer between #{range.min} and #{range.max}") if i.nil? || !range.cover?(i)
        typed[k] = i
      end

      # The circuit has to be able to open before the call budget runs out. A one-call
      # budget is exempt: there is no "before" for the circuit to trip in.
      if typed["judge_max_calls_per_scan"] > 1 && typed["judge_max_provider_errors"] >= typed["judge_max_calls_per_scan"]
        fail_on("judge_max_provider_errors", "must be lower than judge_max_calls_per_scan")
      end

      fail_on("judge_model_name", "is required when the judge is enabled") if typed["judge_enabled"] && typed["judge_model_name"].blank?

      KEYS.index_with { |k| typed.fetch(k) }
    end

    # Whether THIS process can see the key. The web and the worker usually share one
    # environment; the launch status recorded on each report is the authoritative check.
    def key_present?
      ENV[KEY_ENV].present?
    end

    private

    # Errors name the field as the Settings page labels it, not by its storage key.
    LABELS = {
      "judge_enabled" => "Enable LLM judge", "judge_provider" => "Provider", "judge_model_name" => "Model",
      "judge_band_below" => "Band below threshold", "judge_band_above" => "Band above threshold",
      "judge_max_calls_per_scan" => "Max judge calls per scan",
      "judge_max_provider_errors" => "Provider errors before stopping",
      "judge_timeout_seconds" => "Timeout (seconds)", "judge_concurrency" => "Concurrent judge calls"
    }.freeze

    def fail_on(key, message)
      raise ValidationError, "#{LABELS.fetch(key, key.to_s.humanize)} #{message}"
    end
  end
end
