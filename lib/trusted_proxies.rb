# frozen_string_literal: true

require "ipaddr"

# Parses the TRUSTED_PROXIES setting into the objects Rails actually matches against.
#
# ActionDispatch::RemoteIp matches with `proxy === ip`. String#=== is equality, so a
# list of raw strings meant the documented CIDR form ("10.0.0.0/8") matched no address
# at all -- and because a custom list REPLACES Rails' RFC1918 defaults, an operator who
# set this ended up trusting fewer proxies than one who never did, losing real client
# IPs rather than resolving them.
module TrustedProxies
  class InvalidEntry < StandardError; end

  module_function

  # Returns [] for a blank setting, so the caller leaves Rails' defaults in place.
  #
  # Any unparseable entry raises. This is a security control read once at boot: an
  # operator who mistypes one CIDR should find out immediately, not months later from
  # wrong client IPs in an audit trail. Dropping the bad entry instead would leave the
  # control silently half-applied, and dropping ALL of them would fall back to Rails'
  # broader defaults -- trusting MORE than the operator asked for, which is the one
  # direction a proxy allowlist must never fail in.
  def parse(raw)
    entries = raw.to_s.split(",").map(&:strip).reject(&:empty?)

    entries.map do |entry|
      IPAddr.new(entry)
    rescue IPAddr::Error => e
      raise InvalidEntry, "TRUSTED_PROXIES entry #{entry.inspect} is not a valid IP or CIDR: #{e.message}"
    end
  end
end
