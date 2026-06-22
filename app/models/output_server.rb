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
  validate :host_is_safe, if: -> { host.present? }
  validate :endpoint_path_is_safe, if: -> { endpoint_path.present? }

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
    "#{protocol}://#{authority_host}:#{port}#{endpoint_path}"
  end

  def authentication_method
    return :token if access_token.present?
    return :api_key if api_key.present?
    return :basic if username.present? && password.present?
    :none
  end

  # Re-validate the destination at SEND time. Save-time validation can't stop DNS
  # rebinding (a host that resolved to a public IP at save can later point at an
  # internal address), so the send services re-resolve + re-check right before use.
  # Validate the EFFECTIVE host parsed from connection_string (not just the raw host
  # field): a stale row whose endpoint_path injects userinfo — e.g. "@169.254.169.254/x"
  # — would otherwise pass while the connection targets the injected internal host.
  # Returns false when unsafe; callers MUST abort the send.
  def destination_safe?
    return false if host.blank?
    return false unless effective_request_host == normalized_host

    UrlSafetyValidator.safe_host?(host, allow_localhost: UrlSafetyValidator.allow_localhost?).safe?
  end

  # Host actually targeted by connection_string, normalized for comparison (IPv6 literals
  # are bracketed in the URI authority; URI.parse returns them bracketed, so strip them).
  def effective_request_host
    parsed = URI.parse(connection_string).host
    parsed.nil? ? nil : strip_brackets(parsed)
  rescue URI::InvalidURIError
    nil
  end

  def additional_settings_is_valid_json
    begin
      JSON.parse(additional_settings)
    rescue JSON::ParserError => e
      errors.add(:additional_settings, "must be valid JSON. Error: #{e.message}")
    end
  end

  # SECURITY: report data is shipped to this host over raw TCP/HTTP/TLS. Without a
  # check, a tenant could point an "output server" at internal/metadata addresses
  # (SSRF / exfil to internal services). Resolve + block internal ranges.
  def host_is_safe
    # A SIEM host must be a bare hostname/IP. Reject URI delimiters that would change
    # the effective host once concatenated into connection_string — e.g.
    # "example.com@169.254.169.254" (userinfo) or "host/path" — and thereby slip past
    # the resolve-based SSRF check below.
    if host.to_s.match?(%r{[\s/@\\?#%$]})
      errors.add(:host, "contains invalid characters")
      return
    end

    result = UrlSafetyValidator.safe_host?(host, allow_localhost: UrlSafetyValidator.allow_localhost?)
    # Fail closed (incl. unresolvable hosts): an unresolvable host can be rebound to an
    # internal address before report data is shipped to it.
    return if result.safe?

    errors.add(:host, "is not allowed: #{result.error}")
  end

  # SECURITY: endpoint_path is concatenated into connection_string after host:port, so a
  # value like "@169.254.169.254/latest" injects a different host (userinfo) and bypasses
  # host_is_safe. Require a plain path beginning with "/".
  def endpoint_path_is_safe
    path = endpoint_path.to_s
    return if path.start_with?("/") && !path.match?(%r{[@\\]|\s|//})

    errors.add(:endpoint_path, "must be a plain path beginning with '/' (no '@', '\\', whitespace, or '//')")
  end

  private

  # Bracket a bare IPv6 literal so it parses inside a URI authority (a plain "2001:db8::1"
  # makes URI.parse raise, which would fail-close every IPv6 SIEM destination).
  def authority_host
    h = host.to_s
    h.include?(":") && !h.start_with?("[") ? "[#{h}]" : h
  end

  # host with any surrounding IPv6 brackets removed, so it compares equal to the
  # bracket-stripped host parsed back out of connection_string.
  def normalized_host
    strip_brackets(host.to_s)
  end

  def strip_brackets(value)
    value.to_s.delete_prefix("[").delete_suffix("]")
  end
end
