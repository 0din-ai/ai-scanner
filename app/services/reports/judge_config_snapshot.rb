# frozen_string_literal: true

module Reports
  # The exact object garak receives as JUDGE_CONFIG (the contract with
  # script/garak_plugins/detectors/_boundary_judge.py). Built from the global judge
  # settings when a report is created and pinned on reports.judge_config, so every
  # segment of the report -- retries and resumed runs included -- is judged under one
  # configuration, the same way evaluation_threshold is pinned.
  class JudgeConfigSnapshot
    # Exactly these keys: the plugin treats a missing OR an extra key (a custom
    # endpoint_uri among them) as a configuration error and leaves the judge off.
    CONTRACT_KEYS = %w[enabled provider model band_low band_high threshold
                       prompt_version max_calls max_provider_errors timeout_seconds concurrency].freeze

    # {} when the judge is off, or when there is no usable threshold to centre the band
    # on: a band around a guessed threshold would re-decide the wrong outputs.
    def self.build(threshold)
      return {} if threshold.nil?

      t = Float(threshold, exception: false)
      unless t&.finite? && t.between?(0.0, 1.0)
        Rails.logger.warn("JudgeConfigSnapshot: evaluation threshold #{threshold.inspect} outside 0..1; judge not pinned")
        return {}
      end

      settings = begin
        JudgeSettings.validate!(JudgeSettings.stored)
      rescue JudgeSettings::ValidationError => e
        Rails.logger.warn("JudgeConfigSnapshot: stored judge settings do not validate (#{e.message}); judge not pinned")
        return {}
      end
      return {} unless settings["judge_enabled"]

      band_low, band_high = band_for(t, settings["judge_band_below"], settings["judge_band_above"])
      {
        "enabled" => true,
        "provider" => settings["judge_provider"],
        "model" => settings["judge_model_name"],
        "band_low" => band_low,
        "band_high" => band_high,
        "threshold" => t,
        "prompt_version" => JudgeSettings::PROMPT_VERSION,
        "max_calls" => settings["judge_max_calls_per_scan"],
        "max_provider_errors" => settings["judge_max_provider_errors"],
        "timeout_seconds" => settings["judge_timeout_seconds"],
        "concurrency" => settings["judge_concurrency"]
      }
    end

    # The absolute band a threshold and two widths give, clamped to [0, 1].
    def self.band_for(threshold, below, above)
      [ (threshold - below).clamp(0.0, 1.0).round(4), (threshold + above).clamp(0.0, 1.0).round(4) ]
    end
  end
end
