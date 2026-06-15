module WebConfig
  # Shape-validates the optional `auth` block inside a webchat target's web_config.
  # Returns human-readable error strings ([] means valid). Does NOT decrypt or mutate.
  class AuthValidator
    ALLOWED_KEYS      = %w[cookies headers storage_state].freeze
    ALLOWED_SAME_SITE = %w[Strict Lax None].freeze
    MAX_COOKIES       = 50

    def initialize(auth)
      @auth = auth
    end

    def errors
      return [ "auth must be an object" ] unless @auth.is_a?(Hash)

      msgs = []
      unknown = @auth.keys.map(&:to_s) - ALLOWED_KEYS
      msgs << "auth has unsupported key(s): #{unknown.sort.join(', ')}" if unknown.any?
      msgs.concat(cookie_errors(@auth["cookies"]))
      msgs.concat(header_errors(@auth["headers"]))
      msgs.concat(storage_state_errors(@auth["storage_state"]))
      msgs
    end

    private

    def cookie_errors(cookies)
      return [] if cookies.nil?
      return [ "auth.cookies must be an array" ] unless cookies.is_a?(Array)
      return [ "auth.cookies cannot have more than #{MAX_COOKIES} entries" ] if cookies.size > MAX_COOKIES

      cookies.each_with_index.flat_map do |cookie, i|
        prefix = "auth.cookies[#{i}]"
        next [ "#{prefix} must be an object" ] unless cookie.is_a?(Hash)

        errs = []
        errs << "#{prefix}.name is required" if cookie["name"].to_s.strip.empty?
        errs << "#{prefix}.value is required" unless cookie["value"].is_a?(String)
        if cookie["url"].to_s.strip.empty? && cookie["domain"].to_s.strip.empty?
          errs << "#{prefix} must include either 'url' or 'domain'"
        end
        errs << "#{prefix}.secure must be true or false" if cookie.key?("secure") && ![ true, false ].include?(cookie["secure"])
        errs << "#{prefix}.httpOnly must be true or false" if cookie.key?("httpOnly") && ![ true, false ].include?(cookie["httpOnly"])
        if cookie["sameSite"].present? && ALLOWED_SAME_SITE.none? { |v| v.casecmp?(cookie["sameSite"].to_s) }
          errs << "#{prefix}.sameSite must be one of Strict, Lax, None"
        end
        errs
      end
    end

    def header_errors(headers)
      return [] if headers.nil?
      return [ "auth.headers must be an object" ] unless headers.is_a?(Hash)

      headers.filter_map do |key, value|
        "auth.headers['#{key}'] must be a string" unless value.is_a?(String)
      end
    end

    def storage_state_errors(storage_state)
      return [] if storage_state.nil?
      return [ "auth.storage_state must be an object" ] unless storage_state.is_a?(Hash)

      []
    end
  end
end
