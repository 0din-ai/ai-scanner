class SettingsService
  DEFAULTS = {
    "parallel_scans_limit" => 5,
    "parallel_attempts" => 16,
    "custom_header_html" => ""
  }.merge(JudgeSettings::DEFAULTS).freeze

  VALIDATIONS = {
    "parallel_scans_limit" => ->(value) { value.to_s =~ /\A\d+\z/ && value.to_i.between?(1, 20) },
    "parallel_attempts" => ->(value) { value.to_s =~ /\A\d+\z/ && value.to_i.between?(1, 100) },
    "custom_header_html" => ->(value) { value.is_a?(String) }
  }.merge(JudgeSettings::KEYS.to_h { |k| [ k, ->(value) { value.is_a?(String) } ] }).freeze

  class << self
    def parallel_scans_limit
      get("parallel_scans_limit").to_i
    end

    def set_parallel_scans_limit(value)
      value = value.to_i
      if VALIDATIONS["parallel_scans_limit"].call(value)
        set("parallel_scans_limit", value.to_s)
      else
        raise ArgumentError, "Parallel scans limit must be between 1 and 20"
      end
    end

    def parallel_attempts
      get("parallel_attempts").to_i
    end

    def set_parallel_attempts(value)
      value = value.to_i
      if VALIDATIONS["parallel_attempts"].call(value)
        set("parallel_attempts", value.to_s)
      else
        raise ArgumentError, "Parallel attempts must be between 1 and 100"
      end
    end

    def custom_header_html
      get("custom_header_html")
    end

    def set_custom_header_html(value)
      value = value.to_s
      if VALIDATIONS["custom_header_html"].call(value)
        set("custom_header_html", value)
      else
        raise ArgumentError, "Custom header HTML must be a string"
      end
    end

    # The ONE writer for the judge keys. Validates them as a unit first, so a rejected
    # combination leaves no partial rows behind, then writes every key in a single
    # transaction. Returns the typed values.
    def set_judge_settings!(attrs)
      typed = JudgeSettings.validate!(attrs)
      Metadatum.transaction do
        JudgeSettings::KEYS.each { |k| set(k, typed[k].to_s) }
      end
      # `set` cleared each key's cache inside the transaction; a reader that missed in
      # between could have re-cached the pre-commit row, so clear again once durable.
      JudgeSettings::KEYS.each { |k| clear_cache(k) }
      typed
    end

    def get(key)
      Rails.cache.fetch("settings/#{key}", expires_in: 1.hour) do
        setting = Metadatum.find_by(key: key)
        setting&.value || DEFAULTS[key]
      end
    end

    def set(key, value)
      setting = Metadatum.find_or_initialize_by(key: key)
      setting.value = value.to_s
      setting.save!
      clear_cache(key)
      value
    end

    def clear_cache(key = nil)
      if key
        Rails.cache.delete("settings/#{key}")
      else
        Rails.cache.delete_matched("settings/*")
      end
    end

    def all_settings
      settings = {}
      DEFAULTS.keys.each do |key|
        settings[key] = get(key)
      end
      settings
    end
  end
end
