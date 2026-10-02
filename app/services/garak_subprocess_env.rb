# frozen_string_literal: true

# The environment a garak subprocess (scan or validation) starts from. Launchers
# spawn it with unsetenv_others, so it inherits ONLY these names from the worker;
# everything else (SECRET_KEY_BASE, RAILS_MASTER_KEY, encryption keys, cloud
# identity, other DB URLs...) stays out of a process that runs tenant-configured
# generators. Tenant rows and the launcher's own assignments are merged on top.
#
# Every name here is also reserved in GarakEnvKeyGuard: some (proxy userinfo,
# DATABASE_QUEUE_URL, PGSSLKEY) are secrets the child legitimately needs, and a
# tenant's key_env_var must never be able to send them to the target's URI.
module GarakSubprocessEnv
  INHERITED_NAMES = %w[
    PATH LANG LC_ALL LC_CTYPE TZ TMPDIR
    PLAYWRIGHT_BROWSERS_PATH
    DEBUG_LOG_TAIL_BYTES LOG_LEVEL DB_POOL_MIN_CONN DB_POOL_MAX_CONN
    DATABASE_QUEUE_URL GARAK_PLUGIN_CACHE_LOCK
    HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY http_proxy https_proxy no_proxy all_proxy
    SSL_CERT_FILE SSL_CERT_DIR REQUESTS_CA_BUNDLE CURL_CA_BUNDLE
    PGSSLMODE PGSSLROOTCERT PGSSLCERT PGSSLKEY
  ].freeze

  def self.inherited(source = ENV)
    INHERITED_NAMES.each_with_object({}) do |name, env|
      value = source[name]
      env[name] = value unless value.nil?
    end
  end
end
