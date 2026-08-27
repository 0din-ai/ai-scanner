# frozen_string_literal: true

require "rails_helper"
require "yaml"

# A .env file is only an INTERPOLATION source for Compose. A variable that is not named
# in a service's `environment:` block never reaches the container, however carefully an
# operator sets it -- so a setting can be documented, read by the app, and still be inert
# in every deployment. ASSUME_SSL was exactly that, and it decides whether the session
# cookie is issued with Secure.
#
# The contract this pins: a variable .env.example advertises AND the app reads is either
# forwarded by BOTH Compose files, or listed below as deliberately not forwarded with a
# reason. Nothing may sit in the gap silently.
RSpec.describe "deployment environment passthrough" do
  COMPOSE_FILES = %w[docker-compose.yml dist/docker-compose.yml].freeze

  FORWARDED_VARIABLES = %w[
    ASSUME_SSL
    RAILS_ALLOWED_HOSTS
    SESSION_COOKIE_DOMAIN
    ACTION_CABLE_URL
    TRUSTED_PROXIES
    RAILS_LOG_LEVEL
    CLARITY_PROJECT_ID
    RETENTION_DAYS
    MAX_INTERRUPT_RETRIES
    DEBUG_LOG_TAIL_BYTES
  ].freeze

  # Advertised and read, but deliberately NOT forwarded. Each entry is a decision, not an
  # oversight, and .env.example says so where an operator will see it.
  NOT_FORWARDED = {
    # Puma reads PORT. Forwarding it would bind the app to the HOST port while the
    # published mapping still targets container port 80, making the app unreachable.
    "PORT" => "host-side port mapping",
    # Database configuration is deferred as ONE cohesive change rather than because
    # every member is individually blocked. Some are empty-safe today and could be
    # forwarded now; the per-database URL overrides are not (`ENV["DATABASE_QUEUE_URL"]
    # || ...` lets an empty value suppress the automatic suffix), and the database
    # names and pool settings need defaults decided. Splitting the group across two
    # releases would leave a half-configurable database, so it moves together.
    "DATABASE_URL" => "database configuration, deferred as a group",
    "DATABASE_QUEUE_URL" => "database configuration, deferred as a group",
    "DATABASE_CACHE_URL" => "database configuration, deferred as a group",
    "DATABASE_CABLE_URL" => "database configuration, deferred as a group",
    "POSTGRES_PRIMARY_DB" => "database configuration, deferred as a group",
    "POSTGRES_CACHE_DB" => "database configuration, deferred as a group",
    "POSTGRES_QUEUE_DB" => "database configuration, deferred as a group",
    "POSTGRES_CABLE_DB" => "database configuration, deferred as a group",
    "POSTGRES_POOL_SIZE" => "database configuration, deferred as a group",
    "POSTGRES_POOL_TIMEOUT" => "database configuration, deferred as a group",
    "POSTGRES_SSL_MODE" => "database configuration, deferred as a group",
    "POSTGRES_SSL_CERT" => "database configuration, deferred as a group",
    "POSTGRES_SSL_KEY" => "database configuration, deferred as a group",
    "POSTGRES_SSL_ROOT_CERT" => "database configuration, deferred as a group"
  }.freeze

  # The raw `environment:` entries for the scanner service, as written. List form is
  # what makes pass-through-if-set possible, so the shape matters and is not normalised
  # away here.
  # Every environment entry in the file, whatever service it belongs to and whichever
  # syntax it uses -- the required-secret guards live on postgres as well as scanner.
  def compose_entries(path)
    YAML.load_file(Rails.root.join(path), aliases: true)
        .fetch("services").values
        .filter_map { |service| service["environment"] }
        .flat_map { |env| env.is_a?(Array) ? env : env.map { |k, v| "#{k}=#{v}" } }
  end

  def scanner_environment(path)
    entries = YAML.load_file(Rails.root.join(path), aliases: true)
                  .fetch("services").fetch("scanner").fetch("environment")
    raise "#{path} must use list form for environment, found #{entries.class}" unless entries.is_a?(Array)

    entries
  end

  def passthrough_names(path)
    scanner_environment(path).reject { |entry| entry.to_s.include?("=") }
  end

  def assigned_names(path)
    scanner_environment(path).select { |entry| entry.to_s.include?("=") }
                             .map { |entry| entry.split("=", 2).first }
  end

  def all_names(path)
    passthrough_names(path) + assigned_names(path)
  end

  def env_example
    @env_example ||= Rails.root.join(".env.example").read
  end

  # Variables .env.example presents as settings, whether live or commented out.
  def advertised_variables
    env_example.scan(/^\s*#?\s*([A-Z][A-Z0-9_]{2,})=/).flatten.uniq
  end

  # Ruby, Python and ERB/YAML all read the environment differently, and a scan that
  # knows only Ruby's spelling reports a variable as unread when db_notifier.py or
  # database.yml is the thing consuming it.
  ENV_READ_PATTERNS = [
    /ENV(?:\.fetch\(|\[)["']([A-Z0-9_]+)["']/,          # Ruby, including inside ERB
    /os\.environ(?:\.get\(|\[)["']([A-Z0-9_]+)["']/,     # Python
    /os\.getenv\(["']([A-Z0-9_]+)["']/                    # Python
  ].freeze

  def variables_read_by_app
    Dir.glob(Rails.root.join("{app,config,db,lib,script}/**/*.{rb,erb,py,yml,yaml}"))
       .flat_map { |file| ENV_READ_PATTERNS.flat_map { |pattern| File.read(file).scan(pattern) } }
       .flatten.uniq
  end

  COMPOSE_FILES.each do |path|
    context path do
      FORWARDED_VARIABLES.each do |name|
        it "passes #{name} through only when it is set" do
          # A bare name, not `NAME=${NAME:-}`. The assigned form would place an EMPTY
          # STRING in the container for an unset variable, which makes every reader's
          # empty-value behaviour load-bearing -- an empty log level fails Rails'
          # bootstrap outright. A hardcoded value would also satisfy a presence check
          # while pinning every deployment to a constant.
          expect(passthrough_names(path)).to include(name),
            "#{name} must appear as a bare `- #{name}` in #{path}; found " \
            "#{scanner_environment(path).grep(/\A#{name}[=\z]/).inspect}"
        end
      end

      NOT_FORWARDED.each_key do |name|
        it "does not forward #{name}" do
          expect(all_names(path)).not_to include(name),
            "#{name} is listed as deliberately not forwarded; remove it from NOT_FORWARDED " \
            "if that decision has changed"
        end
      end
    end
  end

  it "documents every forwarded variable in .env.example" do
    undocumented = FORWARDED_VARIABLES.reject { |name| env_example.match?(/^\s*#?\s*#{name}=/) }

    expect(undocumented).to be_empty,
      "reaches the container but nothing tells an operator it exists: #{undocumented.join(', ')}"
  end

  it "leaves no advertised, app-read variable unaccounted for" do
    # The rule that keeps the gap from growing back: anything an operator can read about
    # in .env.example and that the app actually consumes is either forwarded or a
    # recorded decision not to forward.
    # Subtracted per file, so a name present in only ONE Compose file cannot hide the
    # drift in the other.
    accounted = FORWARDED_VARIABLES + NOT_FORWARDED.keys +
                COMPOSE_FILES.map { |path| all_names(path) }.reduce(:&)
    read = variables_read_by_app
    unaccounted = advertised_variables.select { |name| read.include?(name) } - accounted

    expect(unaccounted).to be_empty,
      "advertised in .env.example and read by the app, but neither forwarded nor listed " \
      "as deliberately excluded: #{unaccounted.join(', ')}"
  end

  describe "secrets the operator must supply" do
    # Compose guards these with ${VAR:?...}, which fires on an unset or EMPTY value and
    # not on a non-empty one. A placeholder in .env.example therefore sails through the
    # guard, and every deployment that copied the file unchanged shares the value --
    # published, in a public repository. Rails derives the ActiveRecord encryption keys
    # from SECRET_KEY_BASE, so that is the keys protecting stored target credentials.
    #
    # Empty is not laziness here: it is the only value the guard can catch.
    #
    # Derived from the Compose files rather than hand-listed, so a secret added there
    # cannot be left out of this contract by omission.
    def required_secret_names
      COMPOSE_FILES.flat_map { |path| compose_entries(path) }
                   .flat_map { |entry| entry.to_s.scan(/\$\{([A-Z][A-Z0-9_]*):\?/) }
                   .flatten.uniq.sort
    end

    it "finds the secrets Compose refuses to start without" do
      expect(required_secret_names).to include("SECRET_KEY_BASE", "POSTGRES_PASSWORD",
                                               "ADMIN_INITIAL_PASSWORD")
    end

    it "leaves every required secret empty in .env.example so the guard can fire" do
      offenders = required_secret_names.filter_map do |name|
        match = env_example[/^\s*#{name}=(.*)$/, 1]
        # A DELETED assignment must not read as an empty one: nil.to_s would pass while
        # telling an operator nothing about a secret they still have to supply.
        next "#{name} (no assignment line)" if match.nil?

        "#{name}=#{match.strip}" unless match.strip.empty?
      end

      expect(offenders).to be_empty,
        "a non-empty value here passes Compose's required-variable guard and ships as a " \
        "shared secret: #{offenders.join(', ')}"
    end

    it "keeps trailing comments off the required-secret value lines" do
      # Compose strips a trailing comment from a NON-EMPTY value, but with nothing
      # before the `#` it takes the whole remainder as the value -- so
      # `POSTGRES_PASSWORD=   # Required` sets the password to the words "# Required"
      # and passes the required-variable guard just like a placeholder would.
      offenders = required_secret_names.select do |name|
        env_example[/^\s*#{name}=.*$/].to_s.include?("#")
      end

      expect(offenders).to be_empty,
        "value line carries a trailing comment; put it on its own line above: " \
        "#{offenders.join(', ')}"
    end
  end

  describe "a variable an operator sets to nothing" do
    # Pass-through-if-set keeps an UNSET variable out of the container entirely, but an
    # operator can still write `RETENTION_DAYS=` in .env, which forwards an empty string.
    # Readers of forwarded values have to survive that.
    it "leaves the log level valid rather than failing boot" do
      # ENV.fetch's default does NOT apply to an empty string, and an empty level fails
      # Rails' bootstrap with `wrong constant name` -- the app does not start at all.
      expect(Rails.root.join("config/environments/production.rb").read)
        .to include('ENV["RAILS_LOG_LEVEL"].presence || "info"')
      expect { Logger.new(IO::NULL).level = "" }.to raise_error(ArgumentError, /invalid log level/)
    end
  end

  describe Retention::SimpleStrategy, "RETENTION_DAYS parsing" do
    # This setting decides what gets DELETED, so every malformed value must fall back to
    # the default rather than be partially believed.
    def resolved_days(value)
      ClimateControl.modify(RETENTION_DAYS: value) do
        described_class.new.send(:retention_days)
      end
    rescue NameError, NoMethodError
      # No ClimateControl in this suite; drive ENV directly and restore.
      previous = ENV["RETENTION_DAYS"]
      value.nil? ? ENV.delete("RETENTION_DAYS") : ENV["RETENTION_DAYS"] = value
      begin
        described_class.new.send(:retention_days)
      ensure
        previous.nil? ? ENV.delete("RETENTION_DAYS") : ENV["RETENTION_DAYS"] = previous
      end
    end

    {
      nil => "unset",
      "" => "empty",
      "   " => "whitespace",
      "abc" => "non-numeric",
      "5oops" => "partially numeric",
      "1.5" => "decimal",
      "0" => "zero",
      "-7" => "negative"
    }.each do |value, description|
      it "falls back to the default for a #{description} value" do
        expect(resolved_days(value)).to eq(described_class::DEFAULT_RETENTION_DAYS)
      end
    end

    it "honours a valid positive value" do
      expect(resolved_days("30")).to eq(30)
    end
  end

  describe TrustedProxies do
    # RemoteIp matches with `proxy === ip`. String#=== is equality, so a list of raw
    # strings matched no address -- and since a custom list REPLACES Rails' RFC1918
    # defaults, setting it left an operator trusting FEWER proxies than not setting it.
    it "parses CIDRs into objects that actually match addresses" do
      expect("10.0.0.0/8" === "10.1.2.3").to be(false)

      parsed = described_class.parse("10.0.0.0/8,172.16.0.0/12")

      expect(parsed.map(&:class)).to all(eq(IPAddr))
      expect(parsed.any? { |proxy| proxy === "10.1.2.3" }).to be(true)
      expect(parsed.any? { |proxy| proxy === "192.0.2.1" }).to be(false)
    end

    it "returns nothing for a blank setting, leaving Rails' defaults alone" do
      expect(described_class.parse(nil)).to eq([])
      expect(described_class.parse("")).to eq([])
      expect(described_class.parse("  , ")).to eq([])
    end

    it "rejects a list containing an invalid entry" do
      # Not dropped: half-applying a proxy allowlist leaves the control silently wrong.
      expect { described_class.parse("10.0.0.0/8,nonsense") }
        .to raise_error(TrustedProxies::InvalidEntry, /nonsense/)
    end

    it "rejects a wholly invalid list rather than falling back to broader defaults" do
      # Skipping assignment here would restore Rails' RFC1918 defaults -- trusting MORE
      # than the operator asked for, the one direction an allowlist must never fail in.
      expect { described_class.parse("nonsense") }.to raise_error(TrustedProxies::InvalidEntry)
    end
  end
end
