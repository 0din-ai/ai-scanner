# frozen_string_literal: true

require "resolv"
require "ipaddr"

class UrlSafetyValidator
  BLOCKED_RANGES = [
    IPAddr.new("127.0.0.0/8"),       # loopback
    IPAddr.new("10.0.0.0/8"),        # RFC1918
    IPAddr.new("172.16.0.0/12"),     # RFC1918
    IPAddr.new("192.168.0.0/16"),    # RFC1918
    IPAddr.new("169.254.0.0/16"),    # link-local / cloud metadata
    IPAddr.new("0.0.0.0/8"),         # "this" network
    IPAddr.new("::1/128"),           # IPv6 loopback
    IPAddr.new("fc00::/7"),          # IPv6 unique local
    IPAddr.new("fe80::/10"),         # IPv6 link-local
    IPAddr.new("100.64.0.0/10"),     # CGN shared address space (RFC 6598)
    IPAddr.new("240.0.0.0/4"),       # reserved for future use
    IPAddr.new("224.0.0.0/4"),       # multicast
    IPAddr.new("255.255.255.255/32"), # broadcast
    IPAddr.new("::/128"),            # IPv6 unspecified
    IPAddr.new("ff00::/8")           # IPv6 multicast
  ].freeze

  Result = Struct.new(:safe?, :error, :resolved_ips, keyword_init: true)

  def self.safe_url?(url, allow_localhost: false)
    new(url, allow_localhost: allow_localhost).validate
  end

  def self.safe_host?(host, allow_localhost: false)
    new(nil, allow_localhost: allow_localhost).validate_host(host)
  end

  def self.allow_localhost?
    Rails.env.development? || Rails.env.test?
  end

  def self.resolve_addresses(host)
    resolver = Resolv::DNS.new
    resolver.timeouts = [ 2, 2 ]
    results = resolver.getaddresses(host).map(&:to_s)
    return results if results.any?

    Timeout.timeout(4) { Resolv.getaddresses(host) }
  rescue Resolv::ResolvError, Resolv::ResolvTimeout, Timeout::Error
    []
  ensure
    resolver&.close
  end

  def initialize(url, allow_localhost: false)
    @url = url
    @allow_localhost = allow_localhost
  end

  def validate
    uri = parse_uri
    return Result.new("safe?": false, error: "Invalid URL") unless uri
    return Result.new("safe?": false, error: "Only HTTP and HTTPS URLs are allowed") unless http_scheme?(uri)
    return Result.new("safe?": false, error: "URL must not contain credentials") if uri.userinfo.present?
    return Result.new("safe?": false, error: "IPv6 zone IDs are not allowed") if uri.host&.include?("%")

    validate_host(uri.host)
  end

  def validate_host(host)
    return Result.new("safe?": false, error: "Host is blank") if host.blank?

    resolved_ips = resolve_host(host)
    return Result.new("safe?": false, error: "Could not resolve hostname") if resolved_ips.empty?

    resolved_ips.each do |ip_str|
      ip = IPAddr.new(ip_str)
      ip = ip.native if ip.ipv4_mapped? || ip.ipv4_compat?
      BLOCKED_RANGES.each do |range|
        if range.include?(ip)
          next if @allow_localhost && loopback?(ip)
          return Result.new("safe?": false, error: "URL resolves to blocked internal address (#{ip_str})")
        end
      end
    end

    Result.new("safe?": true, error: nil, resolved_ips: resolved_ips)
  rescue IPAddr::InvalidAddressError
    Result.new("safe?": false, error: "Invalid IP address in hostname")
  end

  private

  def parse_uri
    URI.parse(@url)
  rescue URI::InvalidURIError
    nil
  end

  def http_scheme?(uri)
    uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
  end

  def resolve_host(host)
    ip = parse_ip(host)
    return [ ip.to_s ] if ip

    self.class.resolve_addresses(host)
  end

  def parse_ip(str)
    clean = str.gsub(/\A\[|\]\z/, "")
    ip = IPAddr.new(clean)
    ip = ip.native if ip.ipv4_mapped? || ip.ipv4_compat?
    ip
  rescue IPAddr::InvalidAddressError
    nil
  end

  LOOPBACK_V4 = BLOCKED_RANGES[0]
  LOOPBACK_V6 = BLOCKED_RANGES[6]

  def loopback?(ip)
    LOOPBACK_V4.include?(ip) || LOOPBACK_V6.include?(ip)
  end
end
