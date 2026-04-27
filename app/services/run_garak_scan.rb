require "cgi"

class RunGarakScan
  HOST = "localhost"
  LOGS_PATH = Rails.root.join("storage", "logs").expand_path
  CONFIG_PATH = Rails.root.join("storage", "config").expand_path
  EVALUATION_THRESHOLD_ENV_NAME = "EVALUATION_THRESHOLD"

  # Default wait times for web chat interactions (in milliseconds)
  DEFAULT_AFTER_SEND_WAIT = 2000
  DEFAULT_RESPONSE_TIMEOUT = 10000

  attr_reader :report

  def initialize(report)
    @report = report
  end

  def call
    # Only run scan if target has 'good' status
    unless target.status == "good"
      handle_invalid_target_status
      return
    end

    # If all probes already completed (from a previous interrupted run),
    # skip garak and go straight to processing
    if all_probes_completed?
      handle_all_probes_completed
      return
    end

    if MonitoringService.active?
      MonitoringService.transaction("run_garak_scan", "background") do
        MonitoringService.set_label(:report_uuid, report.uuid)
        MonitoringService.set_label(:scan_name, report.scan.name)
        MonitoringService.set_label(:target_name, target.name)

        report.update(status: :starting) unless report.starting?

        execute_scan
      end
    else
      report.update(status: :starting) unless report.starting?
      execute_scan
    end
  end

  private

  def execute_scan
    ActsAsTenant.with_tenant(report.company) do
      argv = build_argv
      env = build_env
      log_path = scan_log_path
      log_scan_debug_info(argv)
      RunCommand.new(argv, env: env).call_async(log_file: log_path)
    rescue RunCommand::ImmediateExitError => e
      Rails.logger.error("Scan process failed to start for report #{report.uuid}: #{e.message}")
      stderr_tail = read_log_tail
      message = "Scan process failed to start (exit status #{e.exit_status})."
      message += " Output: #{stderr_tail}" if stderr_tail.present?
      report.update(status: :failed, logs: message)
    end
  end

  def build_argv
    script_path = Rails.root.join("script", "run_garak.py")
    [ "/opt/venv/bin/python3", script_path.to_s, report.uuid ] + params
  end

  def build_env
    # Tenant context needed for decrypting EnvironmentVariable.env_value
    # via per-tenant key provider
    merged = merged_env_vars
    env = merged.dup

    env["HOME"] = "/home/rails"
    env["VARIANT_SCAN"] = "true" if report.is_variant_report?

    env["LOG_FILE_PATH"] = scan_log_path
    env["DATABASE_URL"] = database_url_for_python

    if MonitoringService.active?
      MonitoringService.trace_context.each do |key, value|
        env[key] = value
      end
    end

    env["REPORT_UUID"] = report.uuid
    env["SCAN_ID"] = report.scan.id.to_s
    env["SCAN_NAME"] = report.scan.name
    env["TARGET_ID"] = target.id.to_s
    env["TARGET_NAME"] = target.name

    env
  end

  def scan_log_path
    @scan_log_path ||= LogPathManager.scan_log_file_for_report(report).to_s
  end

  def log_scan_debug_info(argv)
    if Rails.configuration.log_level.to_s == "debug" || MonitoringService.active?
      trace_id = MonitoringService.current_trace_id
      yellow = "\e[33m"
      reset = "\e[0m"
      separator = yellow + ("-" * 80) + reset
      Rails.logger.info(separator)
      Rails.logger.info(yellow + "GARAK SCAN COMMAND:" + reset)
      Rails.logger.info(yellow + "Report UUID: #{report.uuid}" + reset)
      Rails.logger.info(yellow + "Scan: #{report.scan.name}" + reset)
      Rails.logger.info(yellow + "Target: #{target.name}" + reset)
      Rails.logger.info(yellow + "Monitoring Trace ID: #{trace_id}" + reset) if trace_id
      Rails.logger.info(yellow + "argv: #{argv.inspect}" + reset)
      Rails.logger.info(separator)
    end
  end

  def handle_invalid_target_status
    case target.status
    when "validating"
      error_message = "Target '#{target.name}' is still being validated. Please wait for validation to complete before running scans."
      Rails.logger.warn("Cannot run scan for report #{report.id} - target #{target.id} (#{target.name}) is in 'validating' status")
    when "bad"
      error_message = "Target '#{target.name}' validation failed."
      error_message += " #{target.validation_text}" if target.validation_text.present?
      Rails.logger.error("Cannot run scan for report #{report.id} - target #{target.id} (#{target.name}) has 'bad' status. Validation text: #{target.validation_text}")
    else
      # This shouldn't happen unless there's a new status or data corruption
      error_message = "Target '#{target.name}' is not ready for scanning (status: #{target.status}). Target must be validated successfully before running scans."
      Rails.logger.error("Cannot run scan for report #{report.id} - target #{target.id} (#{target.name}) has unexpected status: #{target.status}")
    end

    report.update(
      status: :failed,
      logs: "Scan failed: #{error_message}"
    )
  end

  def database_url_for_python
    return ENV["DATABASE_URL"] if ENV["DATABASE_URL"].present?

    config = ActiveRecord::Base.connection_db_config.configuration_hash
    host = config[:host]
    port = config[:port] || 5432
    database = config[:database]
    username = config[:username]
    password = config[:password]

    encoded_username = CGI.escape(username.to_s)
    auth = password.present? ? "#{encoded_username}:#{CGI.escape(password)}" : encoded_username
    "postgresql://#{auth}@#{host}:#{port}/#{database}"
  end

  def params
    if target.webchat?
      web_chat_params
    else
      api_params
    end
  end

  def api_params
    [
      [ "--skip_unknown" ],
      target_type_arg,
      target_name_arg,
      probes_config,
      report_prefix,
      evaluation_threshold,
      parallel_attempts,
      generator_options
    ].compact.flatten
  end

  def web_chat_params
    [
      [ "--skip_unknown" ],
      [ "--target_type", "web_chatbot.WebChatbotGenerator" ],
      web_chat_target_name,
      probes_config,
      report_prefix,
      evaluation_threshold,
      parallel_attempts,
      web_chat_generator_options
    ].compact.flatten
  end

  def target
    report.target
  end

  def target_type_arg
    [ "--target_type", "#{Target::INVERTED_MODEL_TYPES[target.model_type]}.#{target.model_type}" ]
  end

  def target_name_arg
    [ "--target_name", target.model ]
  end

  def web_chat_target_name
    [ "--target_name", "web_chatbot" ]
  end

  # Build a temporary YAML config containing the probe_spec, and return --config <path>
  def probes_config
    probes_list = scan_probes

    probes_csv = probes_list.join(",")
    [ "--config", write_probes_yaml(probes_csv) ]
  end

  def generator_options
    return if target.json_config.blank?

    [ "--generator_option_file", temp_json_file_path ]
  end

  def web_chat_generator_options
    return if target.web_config.blank?

    [ "--generator_option_file", temp_web_config_file_path ]
  end

  def temp_json_file_path
    FileUtils.mkdir_p(CONFIG_PATH) unless Dir.exist?(CONFIG_PATH)
    file_path = CONFIG_PATH.join("#{report.uuid}.json")
    config = substitute_env_vars(target.json_config, merged_env_vars)
    File.write(file_path, config)
    file_path.to_s
  rescue StandardError => e
    Rails.logger.error("Failed to create JSON config file: #{e.message}")
    raise
  end

  # Replace $VAR_NAME placeholders in config strings with env var values.
  # Unmatched placeholders (e.g., garak's $INPUT) are left as-is.
  def substitute_env_vars(config_string, env_vars_hash)
    return config_string if config_string.blank?

    config_string.gsub(/\$([A-Za-z_][A-Za-z0-9_]*)/) do
      env_vars_hash.fetch($1, $&)
    end
  end

  # Write a minimal YAML with plugins.probe_spec to avoid huge CLI args
  def write_probes_yaml(probes_csv)
    FileUtils.mkdir_p(CONFIG_PATH) unless Dir.exist?(CONFIG_PATH)
    file_path = CONFIG_PATH.join("#{report.uuid}.yml")

    config = {
      "plugins" => {
        "probe_spec" => probes_csv
      }
    }

    File.write(file_path, config.to_yaml)
    file_path.to_s
  rescue StandardError => e
    Rails.logger.error("Failed to create YAML config file: #{e.message}")
    raise
  end

  def temp_web_config_file_path
    FileUtils.mkdir_p(CONFIG_PATH) unless Dir.exist?(CONFIG_PATH)
    file_path = CONFIG_PATH.join("#{report.uuid}_web.json")

    web_config = target.web_config.is_a?(String) ? JSON.parse(target.web_config) : target.web_config

    # Wrap web_config in garak's expected structure
    garak_config = {
      "web_chatbot" => {
        "WebChatbotGenerator" => web_config
      }
    }

    File.write(file_path, JSON.pretty_generate(garak_config))
    file_path.to_s
  rescue StandardError => e
    Rails.logger.error("Failed to create web config file: #{e.message}")
    raise
  end

  def parallel_attempts
    [ "--parallel_attempts", SettingsService.parallel_attempts.to_s ]
  end

  def report_prefix
    [ "--report_prefix", report.uuid ]
  end

  # Merge global and per-target env vars. Per-target overrides global on name collision.
  # Memoized — called from both build_env and substitute_env_vars.
  def merged_env_vars
    @merged_env_vars ||= begin
      global_vars = EnvironmentVariable
        .global.where.not(env_name: EVALUATION_THRESHOLD_ENV_NAME)
        .select(:env_name, :env_value)
        .map { |ev| [ ev.env_name, ev.env_value ] }
        .to_h

      target_vars = target.environment_variables
        .where.not(env_name: EVALUATION_THRESHOLD_ENV_NAME)
        .select(:env_name, :env_value)
        .map { |ev| [ ev.env_name, ev.env_value ] }
        .to_h

      global_vars.merge(target_vars)
    end
  end

  def evaluation_threshold
    # Tenant context is set by execute_scan's with_tenant wrapper
    env_var = target.environment_variables.find_by(env_name: EVALUATION_THRESHOLD_ENV_NAME) ||
      EnvironmentVariable.global.find_by(env_name: EVALUATION_THRESHOLD_ENV_NAME)

    if env_var&.env_value
      value = env_var.env_value.to_s.strip
      raise ArgumentError, "Invalid evaluation threshold: #{value}" unless value.match?(/\A\d+(\.\d+)?\z/)
      [ "--eval_threshold", value ]
    end
  end

  # Returns the list of remaining probes for a regular report, filtering out
  # probes that already have eval entries in saved partial JSONL data.
  def remaining_probes
    @remaining_probes ||= begin
      all_probes = report.scan.probes.map(&:full_name)
      completed = completed_probes_from_raw_data
      if completed.empty?
        all_probes
      else
        remaining = all_probes - completed.to_a
        log_resumption_info(all_probes.size, remaining.size)
        remaining
      end
    end
  end

  # Returns the probes to run for this scan.
  # For variant reports, maps base probes to their variant probe identifiers.
  def scan_probes
    if report.is_variant_report?
      variant_scan_probes
    else
      remaining_probes
    end
  end

  # Returns variant probe identifiers for a variant (child) report, filtered by
  # any probes already completed in a prior interrupted run.
  def variant_scan_probes
    probe_names = report.variant_probes.map(&:full_name)
    subindustry_ids = report.scan.threat_variant_subindustry_ids

    # Guard: if scan subindustries were cleared after this variant report was
    # created, fall back to all variants for the persisted probes rather than
    # treating the report as "all probes completed" and skipping remaining work.
    all_variant_probes = if subindustry_ids.empty? && report.variant_probes.any?
      Rails.logger.warn(
        "[ScanResume] Report #{report.uuid}: scan subindustries were cleared after " \
        "variant report was created. Falling back to all variants for persisted probes."
      )
      probe_ids = report.variant_probes.pluck(:id)
      ThreatVariant.where(probe_id: probe_ids)
        .pluck(:prompt).uniq
        .map { |p| "0din_variants.#{p}" }
    else
      VariantProbeMapper.new(probe_names, subindustry_ids).call
    end

    completed = completed_probes_from_raw_data
    if completed.empty?
      all_variant_probes
    else
      remaining = all_variant_probes - completed.to_a
      log_resumption_info(all_variant_probes.size, remaining.size) if remaining.size < all_variant_probes.size
      remaining
    end
  end

  # Parses existing raw_report_data JSONL for eval entries to identify completed probes.
  # A probe is "completed" if it has at least one eval entry in the saved data.
  # Memoized because it's called from both all_probes_completed? and probes_config.
  def completed_probes_from_raw_data
    @completed_probes_from_raw_data ||= begin
      raw_data = report.raw_report_data
      if raw_data&.jsonl_data.present?
        completed = Set.new
        raw_data.jsonl_data.each_line do |line|
          line = line.strip
          next if line.empty?
          begin
            entry = JSON.parse(line)
            if GarakEvalRowValidator.valid?(entry, require_probe_detector: true)
              probe_name = entry["probe"]
              completed.add(probe_name)
            end
          rescue JSON::ParserError
            next
          end
        end
        completed
      else
        Set.new
      end
    end
  end

  # Returns true if all probes have already been completed in a previous run.
  def all_probes_completed?
    scan_probes.empty?
  end

  def handle_all_probes_completed
    Rails.logger.info(
      "[ScanResume] Report #{report.uuid}: All probes already completed, " \
      "enqueuing ProcessReportJob directly"
    )
    persist_existing_logs
    ProcessReportJob.perform_later(report.id)
  end

  # Attempt to save the scan log file to raw_report_data before processing.
  # On a resumed scan that skips garak (all probes complete), the log file from
  # the previous run may still exist on disk if we're on the same pod.
  # Searches across date directories since the log may have been created on a
  # previous day (scan crossing a date boundary).
  def persist_existing_logs
    raw_data = report.raw_report_data
    return unless raw_data

    log_path = LogPathManager.find_existing_log_for_report(report)
    return unless log_path&.exist?

    raw_data.update(logs_data: File.read(log_path))
    Rails.logger.info("[ScanResume] Report #{report.uuid}: Persisted existing log file to raw_report_data")
  rescue StandardError => e
    Rails.logger.warn("[ScanResume] Report #{report.uuid}: Could not persist logs: #{e.message}")
  end

  def read_log_tail
    log_path = LogPathManager.scan_log_file_for_report(report)
    return nil unless log_path && File.exist?(log_path.to_s)

    content = File.read(log_path.to_s)
    content.lines.last(10).join.strip.truncate(500)
  rescue StandardError
    nil
  end

  def log_resumption_info(total, remaining)
    completed = total - remaining
    Rails.logger.info(
      "[ScanResume] Report #{report.uuid}: Resuming scan — " \
      "#{completed}/#{total} probes already completed, #{remaining} remaining"
    )
  end
end
