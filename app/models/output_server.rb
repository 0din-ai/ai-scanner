class OutputServer < ApplicationRecord
  acts_as_tenant :company

  encrypts :access_token, key_provider: Encryption::TenantKeyProvider.new
  encrypts :api_key, key_provider: Encryption::TenantKeyProvider.new
  encrypts :password, key_provider: Encryption::TenantKeyProvider.new

  # Known SIEM types (engine can extend via class attribute)
  ALL_SIEM_TYPES = %w[splunk rsyslog].freeze

  # Available types for UI selection
  SIEM_TYPES = %w[splunk rsyslog].freeze

  validates :name, presence: true, uniqueness: { scope: :company_id }
  validates :server_type, presence: true
  validates :server_type, inclusion: { in: ->(r) { r.class.available_server_types }, message: "%{value} is not a supported SIEM type" }
  validates :port, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 65535 }, allow_nil: true
  validates :protocol, inclusion: { in: %w[http https udp tcp tls], message: "%{value} is not a valid protocol" }, allow_nil: false
  validate :additional_settings_is_valid_json, if: -> { additional_settings.present? }

  scope :enabled, -> { where(enabled: true) }

  # Enum uses ALL types for DB compatibility
  enum :server_type, ALL_SIEM_TYPES.each_with_index.to_h
  enum :protocol, %w[http https udp tcp tls].each_with_index.to_h

  # Class-level accessor for available server types.
  # Uses a class attribute so engine concerns can override via class_methods.
  class_attribute :_available_server_types, default: SIEM_TYPES

  def self.available_server_types
    _available_server_types
  end

  def self.ransackable_attributes(auth_object = nil)
    %w[company_id created_at description enabled endpoint_path host id name port protocol server_type updated_at]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[company]
  end

  def connection_string
    "#{protocol}://#{host}:#{port}#{endpoint_path}"
  end

  def authentication_method
    return :token if access_token.present?
    return :api_key if api_key.present?
    return :basic if username.present? && password.present?
    :none
  end

  def additional_settings_is_valid_json
    begin
      JSON.parse(additional_settings)
    rescue JSON::ParserError => e
      errors.add(:additional_settings, "must be valid JSON. Error: #{e.message}")
    end
  end
end
