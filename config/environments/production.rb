require "active_support/core_ext/integer/time"
require "logging"

require "dotenv"
env_file = Rails.root.join("storage", ".env")
Dotenv.load(env_file) if File.exist?(env_file)

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local
  config.active_storage.variant_processor = :disabled

  # Only assume SSL if explicitly set or not running on localhost
  # This allows HTTP access when domain is localhost for local testing
  # For all other domains, SSL is assumed/required
  config.assume_ssl = ENV.fetch("ASSUME_SSL", "false") == "true"

  # Helper to check if running on localhost
  config.is_localhost = ->(request) {
    request.host == "localhost" || request.host == "127.0.0.1"
  }

  config.hosts << "localhost"

  # Extend allowed hosts from environment variable (for Kubernetes or ingress IPs/domains)
  ENV.fetch("RAILS_ALLOWED_HOSTS", "").split(",").reject { |host| host.strip.empty? }.each do |host|
    clean = host.strip
    if clean.start_with?("/") && clean.end_with?("/")
      # Convert to Regexp (strip leading/trailing slashes)
      config.hosts << Regexp.new(clean[1..-2])
    else
      config.hosts << clean
    end
  end

  # SSL termination is handled by the load balancer/ingress, not the container.
  # Set ASSUME_SSL=true when behind a TLS-terminating proxy.
  config.force_ssl = false

  # Trust reverse proxies to read X-Forwarded-For for real client IPs.
  # Set TRUSTED_PROXIES as a comma-separated list of CIDRs in .env.
  # Example: TRUSTED_PROXIES=10.0.0.0/8,172.16.0.0/12
  trusted = ENV.fetch("TRUSTED_PROXIES", "").split(",").map(&:strip).reject(&:empty?)
  config.action_dispatch.trusted_proxies = trusted if trusted.any?

  # Configure SSL options with localhost exception
  config.ssl_options = {
    redirect: {
      exclude: ->(request) {
        # Exclude health check endpoint
        return true if request.path == "/up"
        # Exclude localhost from HTTPS redirect (including IPv6)
        localhost_hosts = [ "localhost", "127.0.0.1", "::1" ]
        return true if localhost_hosts.include?(request.host) ||
                       request.host.match?(/\A127\.0\.0\.\d{1,3}\z/)
        false
      }
    }
  }

  # Configure session cookie domain for WebSocket subdomain access
  # If ACTION_CABLE_URL uses a different subdomain (e.g., wss://ws.example.com/cable),
  # you MUST set SESSION_COOKIE_DOMAIN to share cookies across subdomains.
  # Example: SESSION_COOKIE_DOMAIN=".example.com" allows both example.com and ws.example.com
  #
  # Without this setting, the session cookie defaults to the exact host that served the
  # request and will NOT be sent to WebSocket connections on different subdomains.
  #
  # IMPORTANT: Be careful with this setting as it determines which domains can access
  # the session cookie. Use the most specific domain possible for security.
  # SECURITY: set the session cookie Secure + SameSite flags. With a TLS-terminating
  # proxy (force_ssl=false, ASSUME_SSL=true), Rails does not add Secure automatically,
  # so set it explicitly. Applied whether or not SESSION_COOKIE_DOMAIN is configured.
  session_options = {
    key: "_scanner_session",
    secure: ENV.fetch("ASSUME_SSL", "false") == "true",
    same_site: :lax
  }
  session_options[:domain] = ENV["SESSION_COOKIE_DOMAIN"] if ENV["SESSION_COOKIE_DOMAIN"].present?
  config.session_store :cookie_store, **session_options

  # Configure logging with file rotation and STDOUT output
  log_dir = Rails.root.join("storage/logs/rails")
  FileUtils.mkdir_p(log_dir)

  # Create file logger with rotation
  file_logger = ActiveSupport::Logger.new(
    log_dir.join("application.log"),
    10,           # Keep 10 files max
    100.megabytes # Rotate when file reaches 100MB
  )

  # Also log to STDOUT for Docker
  stdout_logger = ActiveSupport::Logger.new(STDOUT)

  # Use BroadcastLogger to log to both destinations
  config.logger = ActiveSupport::BroadcastLogger.new(
    file_logger,
    stdout_logger
  )

  # Add tagging support
  config.logger = ActiveSupport::TaggedLogging.new(config.logger)
  config.log_tags = [ :request_id ]
  config.log_formatter = Logging::JSONFormatter.new

  # Change to "debug" to log everything (including potentially personally-identifiable information!)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Configure Action Cable allowed origins from environment variable or use localhost defaults
  allowed_hosts = ENV.fetch("RAILS_ALLOWED_HOSTS", "")

  if allowed_hosts.empty?
    # Default to localhost entries when RAILS_ALLOWED_HOSTS is not set
    cable_origins = [ "http://localhost", "https://localhost", "http://localhost:3000", "https://localhost:3000" ]
  else
    cable_origins = []
    allowed_hosts.split(",").reject { |origin| origin.strip.empty? }.each do |origin|
      clean = origin.strip
      if clean.start_with?("/") && clean.end_with?("/")
        # Convert to Regexp (strip leading/trailing slashes)
        cable_origins << Regexp.new(clean[1..-2])
      else
        cable_origins << "http://#{clean}"
        cable_origins << "https://#{clean}"
      end
    end
  end

  config.action_cable.allowed_request_origins = cable_origins

  # Configure Action Cable URL from environment variable (e.g., for separate WebSocket subdomain)
  if ENV["ACTION_CABLE_URL"].present?
    config.action_cable.url = ENV["ACTION_CABLE_URL"]
  end

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
