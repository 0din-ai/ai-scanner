class Target < ApplicationRecord
  acts_as_tenant :company

  encrypts :json_config, key_provider: Encryption::TenantKeyProvider.new
  encrypts :web_config,  key_provider: Encryption::TenantKeyProvider.new

  DEFAULT_MODEL_TYPES = { "openai" => [ "gpt-3.5-turbo", "gpt-4" ], "anthropic" => [ "claude-2", "claude-instant" ], "web_chatbot" => [ "WebChatbotGenerator" ] }.freeze
  MODEL_TYPES = begin
    json_path = Rails.root.join("config", "probes", "generators.json")
    if File.exist?(json_path)
      JSON.parse(File.read(json_path))
    else
      DEFAULT_MODEL_TYPES
    end
  end
  INVERTED_MODEL_TYPES = MODEL_TYPES.each_with_object({}) do |(platform, models), result|
    models.each { |model| result[model] = platform }
  end

  enum :status, {
    validating: 0,
    good: 1,
    bad: 2
  }

  enum :target_type, {
    api: 0,
    webchat: 1
  }

  MODEL_FORMAT = /\A[a-zA-Z0-9\-_\/.:@]+\z/

  validates :name, presence: true, uniqueness: { scope: :company_id }
  validates :model_type, presence: true, if: :api?
  validates :model_type, inclusion: { in: INVERTED_MODEL_TYPES.keys, message: "%{value} is not a recognized generator type" }, if: -> { api? && model_type.present? }
  validates :model, presence: true, if: :api?
  validates :model, format: { with: MODEL_FORMAT, message: "contains invalid characters (only letters, numbers, hyphens, underscores, slashes, dots, colons, and @ are allowed)" }, if: -> { api? && model.present? }
  validate :json_config_is_valid_json, if: :json_config_should_be_validated?
  validate :web_config_is_valid, if: :webchat?

  before_validation :set_defaults_for_webchat

  has_many :environment_variables, dependent: :destroy
  has_many :reports, dependent: :destroy
  has_and_belongs_to_many :scans

  after_create :validate_target!
  after_save :validate_target_on_config_change

  default_scope { where(deleted_at: nil) }

  # SECURITY: Use unscope(where: :deleted_at) instead of unscoped to preserve
  # acts_as_tenant isolation. Using unscoped removes ALL default scopes including
  # tenant scoping, which would allow cross-tenant data access.
  scope :deleted, -> { unscope(where: :deleted_at).where.not(deleted_at: nil) }
  scope :with_deleted, -> { unscope(where: :deleted_at) }

  def validate_target!
    ValidateTargetJob.perform_later(id)
  end

  def validate_target_now!
    ValidateTarget.new(self).call
  end

  def mark_deleted!
    update!(deleted_at: Time.current)
  end

  def deleted?
    deleted_at.present?
  end

  def restore!
    update!(deleted_at: nil)
  end

  def self.ransackable_attributes(auth_object = nil)
    [ "company_id", "description", "created_at", "id", "model", "model_type", "name", "updated_at", "deleted_at", "status", "target_type", "tokens_per_second" ]
  end

  def self.ransackable_associations(auth_object = nil)
    [ "company", "environment_variables", "reports" ]
  end

  def web_chat_url
    config = parsed_web_config
    config&.dig("url")
  end

  def web_chat_selectors
    config = parsed_web_config
    return {} unless config&.dig("selectors")

    {
      input: config.dig("selectors", "input"),
      send_button: config.dig("selectors", "send_button"),
      response_area: config.dig("selectors", "response_area")
    }
  end

  def parsed_web_config
    return nil if web_config.blank?
    web_config.is_a?(String) ? JSON.parse(web_config) : web_config
  rescue JSON::ParserError => e
    Rails.logger.warn("Target#parsed_web_config: invalid JSON for target #{id}: #{e.message}")
    nil
  end

  def display_model_info
    if webchat?
      "Web Chat: #{web_chat_url}"
    else
      "#{model_type}: #{model}"
    end
  end

  # Normalize Hash/Array to JSON string before the encrypted attribute type
  # casts via .to_s (which produces Ruby notation, not valid JSON).
  def json_config=(value)
    super(value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value)
  end

  def web_config=(value)
    super(value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value)
  end

  private

  def json_config_should_be_validated?
    json_config.present? && api?
  end

  def set_defaults_for_webchat
    if webchat?
      self.model_type = "web_chatbot" if model_type.blank?
      self.model = "WebChatbotGenerator" if model.blank?
    end
  end

  def validate_target_on_config_change
    # after_create already calls validate_target!, skip duplicate on creation
    return if previously_new_record?

    # Compare decrypted plaintext for encrypted fields instead of using
    # saved_change_to_json_config?/saved_change_to_web_config?, which compare
    # ciphertext. Non-deterministic encryption produces different ciphertext on
    # every save, causing spurious change detection.
    config_changed = saved_change_to_model_type? ||
      saved_change_to_model? ||
      saved_change_to_target_type? ||
      json_config != json_config_before_last_save ||
      web_config != web_config_before_last_save

    validate_target! if config_changed
  end

  def json_config_is_valid_json
    JSON.parse(json_config)
  rescue JSON::ParserError => e
    errors.add(:json_config, "must be valid JSON. Error: #{e.message}")
  end

  def web_config_is_valid
    return if web_config.blank?

    config = web_config.is_a?(String) ? JSON.parse(web_config) : web_config

    # Validate URL (required)
    if config["url"].blank?
      errors.add(:web_config, "must include a URL")
      return
    elsif !valid_url?(config["url"])
      errors.add(:web_config, "must include a valid URL")
      return
    end

    # Validate selectors object exists
    if config["selectors"].blank?
      errors.add(:web_config, "must include a 'selectors' object with input_field and response_container")
      return
    end

    # Validate required selector fields
    selectors = config["selectors"]

    if selectors["input_field"].blank?
      errors.add(:web_config, "selectors must include 'input_field' (CSS selector for chat input)")
    end

    if selectors["response_container"].blank?
      errors.add(:web_config, "selectors must include 'response_container' (CSS selector for chat response area)")
    end

    # Optional fields: send_button, response_text, wait_times, detection, browser_options
  rescue JSON::ParserError => e
    errors.add(:web_config, "must be valid JSON. Error: #{e.message}")
  end

  def valid_url?(url)
    result = UrlSafetyValidator.safe_url?(url, allow_localhost: UrlSafetyValidator.allow_localhost?)
    result.safe?
  end
end
