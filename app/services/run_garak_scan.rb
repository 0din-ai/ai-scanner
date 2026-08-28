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
    # Remember which attempt this instance is, independently of the row, which any
    # other pod may change under us.
    @execution_token = report.execution_token
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
      # Pin BEFORE returning. This path skips garak entirely and never builds argv, so
      # without it a report with no snapshot goes straight to processing unpinned:
      # processing would resolve the live value without persisting it, and a variant
      # child generated after a later config edit would resolve a different one,
      # leaving parent and child incomparable.
      report.pin_evaluation_threshold!
      handle_all_probes_completed
      return
    end

    # Re-validate the URL the scan will actually reach, just before launch. Save-time
    # validation can't stop DNS rebinding — the host may resolve to an internal address
    # by now even if it was safe when the target was saved. Covers the webchat URL as
    # well as the RestGenerator one; the browser path is reachable the same way.
    # Only reached when garak will actually run.
    unless target.scan_launch_url_safe?
      handle_unsafe_target_uri
      return
    end

    if MonitoringService.active?
      MonitoringService.transaction("run_garak_scan", "background") do
        MonitoringService.set_label(:report_uuid, report.uuid)
        MonitoringService.set_label(:scan_name, report.scan.name)
        MonitoringService.set_label(:target_name, target.name)

        return unless start_execution_attempt!

        execute_scan
      end
    else
      return unless start_execution_attempt!

      execute_scan
    end
  rescue StandardError
    # Remove the credential-bearing web config (cookies/headers/storageState) only
    # when nothing was spawned: in that case the Python-side cleanup will never run
    # and the file would be orphaned. Once call_async has been entered the process may
    # be alive and may not have read its --generator_option_file yet, so deleting it
    # would race a live scan; that process removes the file on its own exit paths.
    unless @scan_process_may_be_running
      # A replacement attempt owns the UUID-keyed credential file in that case.
      @execution_attempt_replaced = execution_attempt_replaced? if @execution_attempt_replaced.nil?
      remove_web_config_file unless @execution_attempt_replaced
    end
    raise
  end

  private

  # Claim this report for one execution attempt, returning false when someone else
  # already holds it.
  #
  # The normal path claims in StartPendingScansJob and arrives here already starting,
  # so this is a no-op. A caller arriving in any other status (a variant child, a mock
  # target) would otherwise launch a process that cannot prove ownership of the
  # attempt, and the process refuses to run without a token.
  #
  # The claim is a single conditional UPDATE rather than a read-then-write: those
  # callers create a *pending* report, which StartPendingScansJob is free to claim in
  # between, and a read-then-write would overwrite that attempt's token and leave two
  # garak processes running for one report.
  def start_execution_attempt!
    if report.starting?
      # Already ours: StartPendingScansJob claimed it before handing the report over,
      # which is how every ordinary run arrives. The claim below is a no-op here, and
      # the plan used to be recorded inside it -- so an ordinary run never recorded one
      # at all, and nothing downstream could tell a run that finished its whole plan
      # from one that stopped a third of the way through.
      #
      # Recorded only by whoever OWNS the attempt. A caller that goes on to lose the
      # claim must not write a plan: it would be derived from the probe list as that
      # caller saw it, and Scanner.run_hooks(:before_scan_start) can still change which
      # probes the winner actually runs. A stale higher plan survives "never lower" and
      # marks the winner's complete run partial.
      record_planned_probe_count!
      return true
    end

    token = SecureRandom.uuid
    claimed = Report.where(id: report.id).where.not(status: :starting).update_all(
      status: :starting,
      execution_token: token,
      updated_at: Time.current
    ).positive?

    if claimed
      # Reflect the claim in memory rather than reloading: a reload would also drop
      # the loaded target association and re-query it under whatever tenant happens
      # to be current here, which is outside the with_tenant block below.
      report.assign_attributes(status: :starting, execution_token: token)
      report.changes_applied
      @execution_token = token
      record_planned_probe_count!
    else
      Rails.logger.info(
        "[RunGarakScan] report #{report.id} was claimed by another process; " \
        "not launching a second scan for it"
      )
    end

    claimed
  end

  # Release the attempt after a failure that happened BEFORE anything was spawned, so
  # a retry can claim it immediately instead of waiting out the stuck-starting reaper.
  # Never call this once the process may be alive: revoking under a running scanner
  # makes its own running-claim match zero rows and the process exits.
  #
  # update_columns: the report may be mid-failure elsewhere, and this must not fire
  # callbacks or fail on validation. Losing the revoke is not fatal -- the stale
  # reaper clears it -- so failure is logged rather than raised over the original error.
  # Returns false when a DIFFERENT attempt owns the report -- this process must then
  # touch neither the row nor the credential file -- true when the attempt was ours
  # (or the row is gone), and nil when ownership could not be determined.
  # Capture what this run set out to execute, while it is still true. The scan's
  # probe list can change afterwards (an edit, AutoUpdateScanProbesJob), so a count
  # read later describes a plan this run never had.
  #
  # Raised but never lowered. AutoUpdateScanProbesJob can add probes between attempts
  # and a resumed run executes them, while processed_scope counts results from every
  # attempt -- a plan frozen at the first launch would render as "7 of 5 probes". A
  # scan edited down must equally not shrink a plan this report already exceeded.
  def record_planned_probe_count!
    planned = report.planned_probe_count_for_run
    return if planned.nil? || planned.zero?

    # Conditional UPDATE, not read-then-write. Two attempts can both read the old value
    # and let the SMALLER write land last, which is the one direction this must never
    # go: a plan below what the run actually executed marks a complete run partial.
    # `status: :starting` is part of the predicate, not a Ruby check before it.
    # Callers reach here having read `report.starting?` from a possibly stale
    # in-memory record: another process may have claimed, finished or failed the
    # report since it was loaded, and writing a plan for an attempt we no longer own
    # can raise it above what the winner actually runs -- which "never lower" then
    # preserves, marking a complete run partial. Only a report the DATABASE still
    # shows as claimed for launch gets a plan.
    updated = Report.unscoped
                    .where(id: report.id, status: Report.statuses[:starting])
                    .where("planned_probe_count IS NULL OR planned_probe_count < ?", planned)
                    .update_all(planned_probe_count: planned)
    return unless updated.positive?

    # Reflect the write in memory without marking it dirty, so a later save on this
    # instance cannot push a stale value back over a concurrent attempt's higher plan.
    report.write_attribute(:planned_probe_count, planned)
    report.clear_attribute_changes([ :planned_probe_count ])
  rescue StandardError => e
    Rails.logger.warn(
      "[RunGarakScan] failed to record planned probe count for #{report.uuid}: #{e.class}: #{e.message}"
    )
  end

  def revoke_execution_token_after_launch_failure
    Report.unscoped.transaction do
      current_report = Report.unscoped.lock.find_by(id: report.id, company_id: report.company_id)
      next true unless current_report
      next false if current_report.execution_token.present? && current_report.execution_token != @execution_token

      current_report.update_columns(execution_token: nil) if current_report.execution_token == @execution_token
      true
    end
  rescue StandardError => e
    Rails.logger.warn(
      "[RunGarakScan] failed to revoke execution token for #{report.uuid}: #{e.class}: #{e.message}"
    )
    nil
  end

  def execution_attempt_replaced?
    current_token = Report.unscoped.where(id: report.id, company_id: report.company_id).pick(:execution_token)
    current_token.present? && current_token != @execution_token
  rescue StandardError => e
    Rails.logger.warn(
      "[RunGarakScan] failed to check execution ownership for #{report.uuid}: #{e.class}: #{e.message}"
    )
    nil
  end

  # Records a launch failure only while this attempt still owns the report. A user's
  # stop, or a replacement attempt, can land between the process exiting and this
  # write; an unconditional update would turn a stopped report into a failed one.
  # Returns false when a different attempt has taken over.
  def record_launch_failure(message)
    Report.unscoped.transaction do
      current_report = Report.unscoped.lock.find_by(id: report.id, company_id: report.company_id)
      next true unless current_report
      next false if current_report.execution_token.present? && current_report.execution_token != @execution_token
      next true unless current_report.starting?

      # Write through the instance we already hold, whose associations are loaded, and
      # skip validation: this records a terminal failure state, touches nothing a
      # validation guards, and must not be silently dropped -- `update` returning false
      # would leave the report stuck in `starting` until the reaper timed it out.
      report.assign_attributes(status: :failed, execution_token: nil, logs: message)
      unless report.save(validate: false)
        Rails.logger.warn("[RunGarakScan] could not record launch failure for #{report.uuid}")
      end
      true
    end
  rescue StandardError => e
    Rails.logger.warn(
      "[RunGarakScan] failed to record launch failure for #{report.uuid}: #{e.class}: #{e.message}"
    )
    true
  end

  # Deletes the per-scan web config file written by temp_web_config_file_path.
  # Safe no-op for API targets (no such file) or when it was never created.
  def remove_web_config_file
    path = CONFIG_PATH.join("#{report.uuid}_web.json")
    File.delete(path) if File.exist?(path)
  rescue StandardError => e
    Rails.logger.warn("[RunGarakScan] failed to remove web config file for #{report.uuid}: #{e.message}")
  end

  def execute_scan
    ActsAsTenant.with_tenant(report.company) do
      argv = build_argv
      env = build_env
      log_path = scan_log_path
      log_scan_debug_info(argv)
      # on_spawn fires once a child actually exists. popen3 can raise before that -- a
      # missing interpreter, EAGAIN from process creation -- and those failures leave
      # nothing running, so the attempt and its credential file must be released.
      RunCommand.new(argv, env: env).call_async(
        log_file: log_path,
        on_spawn: -> { @scan_process_may_be_running = true }
      )
    rescue RunCommand::ImmediateExitError => e
      # RunCommand raises this only after wait_thr confirms the process terminated, so
      # nothing is racing us for the process itself. The report row is another matter:
      # a stop or a replacement attempt can land between the exit and this write.
      @scan_process_may_be_running = false
      Rails.logger.error("Scan process failed to start for report #{report.uuid}: #{e.message}")
      stderr_tail = read_log_tail
      message = "Scan process failed to start (exit status #{e.exit_status})."
      message += " Output: #{stderr_tail}" if stderr_tail.present?
      @execution_attempt_replaced = record_launch_failure(message) == false
      remove_web_config_file unless @execution_attempt_replaced
    rescue StandardError
      unless @scan_process_may_be_running
        @execution_attempt_replaced = revoke_execution_token_after_launch_failure == false
      end
      raise
    end
  end

  def build_argv
    with_report_tenant do
      script_path = Rails.root.join("script", "run_garak.py")
      [ "/opt/venv/bin/python3", script_path.to_s, report.uuid ] + params
    end
  end

  def build_env
    with_report_tenant do
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
      # Unconditional: merged_env_vars above is tenant-controlled and has no reserved
      # name blocklist, so a conditional assignment would let a tenant row named
      # SCAN_EXECUTION_TOKEN survive and defeat the scanner's fail-closed guard.
      env["SCAN_EXECUTION_TOKEN"] = report.execution_token.to_s
      env["SCAN_ID"] = report.scan.id.to_s
      env["SCAN_NAME"] = report.scan.name
      env["TARGET_ID"] = target.id.to_s
      env["TARGET_NAME"] = target.name

      env
    end
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

  def handle_unsafe_target_uri
    error_message = "Target '#{target.name}' URL failed a safety check (it may resolve to a disallowed address). The scan was aborted."
    Rails.logger.error("[RunGarakScan] aborting report #{report.id}: target #{target.id} (#{target.name}) URL failed the SSRF recheck")
    sanitized = Reports::FailureClassifier.sanitize_text(error_message)
    report.update(
      status: :failed,
      execution_token: nil,
      logs: "Scan failed: #{sanitized}",
      failure_code: "target_url_unsafe",
      failure_message: sanitized,
      failure_details: {
        "target_id" => target.id,
        "target_name" => Reports::FailureClassifier.sanitize_text(target.name)
      }
    )
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

    sanitized_error_message = Reports::FailureClassifier.sanitize_text(error_message)
    report.update(
      status: :failed,
      execution_token: nil,
      logs: "Scan failed: #{sanitized_error_message}",
      failure_code: "target_validation_failed",
      failure_message: sanitized_error_message,
      failure_details: {}
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
    with_report_tenant do
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
  end

  def web_chat_params
    with_report_tenant do
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

    # Hand both browser layers the same blocklist UrlSafetyValidator enforces. The
    # route guard refuses visible HTTP requests early; the screening proxy owns DNS
    # and the exact transport connection, including redirects and WebSockets.
    # WebChatbotGenerator refuses to launch if either layer is missing.
    garak_config = {
      "web_chatbot" => {
        "WebChatbotGenerator" => (web_config.is_a?(Hash) ? web_config : {}).merge(
          "network_guard" => BrowserAutomation::NetworkGuard.payload,
          "screening_proxy" => BrowserAutomation::NetworkGuard.proxy_payload
        )
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
    # The report's snapshot, never a fresh resolve. It is written once at creation and
    # survives retries, so every segment of a report -- including one relaunched after
    # an interruption -- is evaluated against the same value. Re-resolving here would
    # let an edit to EVALUATION_THRESHOLD land mid-report and desync garak's own passed
    # count from the success flags derived at processing time.
    #
    # A report with no snapshot predates the column, or was created by an old pod
    # during a rolling deploy. pin_evaluation_threshold! resolves it once and PERSISTS
    # it before this launch, so processing cannot later resolve a different value.
    #
    # Always emitted, including at the default. Omitting the flag would leave garak to
    # apply its own default -- a second default that happens to equal ours today;
    # passing the resolved value explicitly removes the chance of the two drifting.
    value = with_report_tenant { report.pin_evaluation_threshold! }
    return if value.nil?

    # Checked as a NUMBER, not as decimal text. EnvironmentVariable validates this
    # value with `numericality: 0..1`, which accepts 0.00001 -- and Float#to_s renders
    # that as "1.0e-05", which a decimal-only pattern rejects. Matching on the string
    # would fail the scan while building argv for a threshold the app accepted.
    # garak parses the flag with float(), which reads exponent notation fine.
    threshold = Float(value)
    unless threshold.finite? && threshold.between?(0, 1)
      raise ArgumentError, "Invalid evaluation threshold: #{value.inspect}"
    end

    [ "--eval_threshold", threshold.to_s ]
  end

  def with_report_tenant(&block)
    return yield if ActsAsTenant.current_tenant == report.company

    ActsAsTenant.with_tenant(report.company, &block)
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
  # Delegated so resumption and the progress card cannot disagree about what "done"
  # means. The definition -- a probe with at least one valid eval row -- was already
  # here; JournalSummary is where it now lives, and it reads the journal through SQL
  # rather than pulling a long run's whole jsonl_data column into Ruby.
  def completed_probes_from_raw_data
    @completed_probes_from_raw_data ||= Reports::JournalSummary.for(report).completed_probes
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
    # Non-raising: this scan is already finished, and losing the revoke here would
    # otherwise strand a complete result set in `starting` until the reaper failed it.
    revoke_execution_token_after_launch_failure
    ProcessReportJob.perform_later(report.id)
  end

  # Attempt to save the scan log file to raw_report_data before processing.
  # On a resumed scan that skips garak (all probes complete), the log file from
  # the previous run may still exist on disk if we're on the same pod.
  # Searches across date directories since the log may have been created on a
  # previous day (scan crossing a date boundary).
  def persist_existing_logs
    raw_data = report.raw_report_data
    return if raw_data.nil? || raw_data.logs_data.present?

    log_path = LogPathManager.find_existing_log_for_report(report)
    return unless log_path&.exist?

    raw_data.update!(logs_data: File.read(log_path))
    Rails.logger.info("[ScanResume] Report #{report.uuid}: Persisted existing log file to raw_report_data")
  rescue StandardError => e
    Rails.logger.warn("[ScanResume] Report #{report.uuid}: Could not persist logs: #{e.message}")
  end

  def read_log_tail
    log_path = scan_log_path
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
