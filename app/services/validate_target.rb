class ValidateTarget
  LOGS_PATH = Rails.root.join("storage", "logs").expand_path
  CONFIG_PATH = Rails.root.join("storage", "config").expand_path
  VALIDATION_REPORTS_PATH = Rails.root.join("..", "home", "rails", ".local", "share", "garak", "garak_runs").expand_path

  attr_reader :target

  def initialize(target)
    @target = target
  end

  def call
    require "logging"
    target.update(status: :validating)

    @validation_start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    t0 = @validation_start_time
    Logging.with(event: "validation.started", target_id: target.id, target_name: target.name, model_type: target.model_type, model: target.model, validation_uuid: validation_uuid) do
      Rails.logger.info("validation.started")
    end

    begin
      if target.webchat?
        ValidateWebChatTarget.new(target).call
      else
        Rails.logger.info("validation.invoking")
        RunCommand.new(build_argv, env: build_env).call(log_file: validation_log_path)
        result = process_validation_result
        dur_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
        Logging.with(event: "validation.finished", target_id: target.id, validation_uuid: validation_uuid, decision: (target.good? ? "valid" : "invalid"), response_count: result[:response_count], evaluation: result[:evaluation_result], duration_ms: dur_ms) do
          Rails.logger.info("validation.finished")
        end
      end
    rescue StandardError => e
      dur_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      Logging.with(event: "validation.error", target_id: target.id, validation_uuid: validation_uuid, exception_class: e.class.name, exception_message: e.message.to_s, duration_ms: dur_ms) do
        Rails.logger.error("validation.error")
      end
      target.update(status: :bad, validation_text: "Validation failed: #{e.message}")
    end
  end

  private

  def build_argv
    script_path = Rails.root.join("script", "run_garak.py")
    [ "/opt/venv/bin/python3", script_path.to_s, validation_uuid ] + params
  end

  def build_env
    env = merged_env_vars_hash.dup
    env["HOME"] = "/home/rails"
    env
  end

  def validation_log_path
    FileUtils.mkdir_p(LOGS_PATH) unless Dir.exist?(LOGS_PATH)
    LOGS_PATH.join("#{validation_uuid}.log").to_s
  end

  def merged_env_vars_hash
    @merged_env_vars_hash ||= begin
      # Tenant context is provided by the caller (ValidateTargetJob or controller)
      # Per-target vars override global vars with the same name
      global_vars = EnvironmentVariable
        .global.where.not(env_name: "EVALUATION_THRESHOLD")
        .select(:env_name, :env_value)
        .map { |ev| [ ev.env_name, ev.env_value ] }
        .to_h

      target_vars = target.environment_variables
        .where.not(env_name: "EVALUATION_THRESHOLD")
        .select(:env_name, :env_value)
        .map { |ev| [ ev.env_name, ev.env_value ] }
        .to_h

      global_vars.merge(target_vars)
    end
  end

  def params
    [
      target_type_arg,
      target_name_arg,
      probe,
      report_prefix,
      generator_options
    ].compact.flatten
  end

  def target_type_arg
    [ "--target_type", "#{Target::INVERTED_MODEL_TYPES[target.model_type]}.#{target.model_type}" ]
  end

  def target_name_arg
    [ "--target_name", target.model ]
  end

  def probe
    [ "--probes", Scanner.configuration.validation_probe ]
  end

  def generator_options
    return if target.json_config.blank?

    [ "--generator_option_file", temp_json_file_path ]
  end

  def temp_json_file_path
    FileUtils.mkdir_p(CONFIG_PATH) unless Dir.exist?(CONFIG_PATH)
    file_path = CONFIG_PATH.join("#{validation_uuid}.json")
    config = substitute_env_vars(target.json_config, merged_env_vars_hash)
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

  def report_prefix
    [ "--report_prefix", validation_uuid ]
  end

  def validation_uuid
    @validation_uuid ||= "validation_#{target.id}_#{SecureRandom.hex(8)}"
  end

  def process_validation_result
    jsonl_file_path = VALIDATION_REPORTS_PATH.join("#{validation_uuid}.report.jsonl")

    unless File.exist?(jsonl_file_path)
      target.update(status: :bad, validation_text: "Validation report file not found")
      Logging.with(target_id: target.id, validation_uuid: validation_uuid) do
        Rails.logger.warn("validation.report_missing")
      end
      return { decision: "invalid", response_count: 0, evaluation_result: nil }
    end

    has_responses = false
    response_count = 0
    sample_response = nil
    evaluation_result = nil
    total_output_tokens = 0

    File.open(jsonl_file_path, "r").each_with_index do |line, index|
      line = line.strip
      next if line.empty?

      data = JSON.parse(line)
      next unless data.is_a?(Hash)

      if data["entry_type"] == "attempt"
        output_texts = normalized_outputs(data["outputs"]).filter_map do |output|
          TokenEstimator.extract_output_text(output).presence
        end

        if output_texts.any?
          has_responses = true
          response_count += 1
          # Store only the first response as a sample
          sample_response ||= output_texts.first.to_s.truncate(150)
          # Count output tokens for performance measurement
          output_texts.each do |text|
            total_output_tokens += TokenEstimator.estimate_tokens(text)
          end
        end
      elsif data["entry_type"] == "eval"
        validation = GarakEvalRowValidator.call(data)
        evaluation_result = "#{validation.passed}/#{validation.total_evaluated} attempts passed" if validation.valid?
      end
    rescue JSON::ParserError => e
      Rails.logger.warn("Validation report JSON parse error on line #{index + 1}: #{e.message}")
    end

    if has_responses && evaluation_result.present?
      validation_text = "Target validated successfully - received #{response_count} response(s). "
      validation_text += "Sample response: #{sample_response}. " if sample_response
      validation_text += "Evaluation: #{evaluation_result}." if evaluation_result

      # Calculate tokens per second for performance estimation
      update_attrs = { status: :good, validation_text: validation_text.strip }
      tokens_per_second = calculate_tokens_per_second(total_output_tokens)
      if tokens_per_second
        update_attrs[:tokens_per_second] = tokens_per_second
        update_attrs[:tokens_per_second_sample_count] = 1
      end

      target.update(update_attrs)
      Logging.with(target_id: target.id, validation_uuid: validation_uuid, response_count: response_count, evaluation: evaluation_result) do
        Rails.logger.info("validation.result.valid")
      end
      decision = "valid"
    else
      validation_text = if has_responses
        "Target validation failed: No valid evaluation results received."
      else
        "Target validation failed: No responses received."
      end
      validation_text += " Evaluation: #{evaluation_result}." if evaluation_result

      target.update(
        status: :bad,
        validation_text: validation_text.strip
      )
      Logging.with(target_id: target.id, validation_uuid: validation_uuid, evaluation: evaluation_result) do
        Rails.logger.warn("validation.result.invalid")
      end
      decision = "invalid"
    end

    cleanup_validation_files
    { decision: decision, response_count: response_count, evaluation_result: evaluation_result }
  end

  def normalized_outputs(outputs)
    case outputs
    when Array
      outputs
    when Hash, String
      [ outputs ]
    else
      []
    end
  end

  # Calculate tokens per second from validation timing
  # Returns nil if insufficient data for calculation
  def calculate_tokens_per_second(total_output_tokens)
    return nil unless @validation_start_time
    return nil if total_output_tokens <= 0

    duration_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @validation_start_time
    return nil if duration_seconds <= 0

    (total_output_tokens / duration_seconds).round(2)
  end

  def cleanup_validation_files
    # Clean up temporary files
    config_file = CONFIG_PATH.join("#{validation_uuid}.json")
    log_file = LOGS_PATH.join("#{validation_uuid}.log")
    report_file = VALIDATION_REPORTS_PATH.join("#{validation_uuid}.report.jsonl")

    [ config_file, log_file, report_file ].each do |file|
      File.delete(file) if File.exist?(file)
    rescue StandardError => e
      Rails.logger.warn("Failed to cleanup validation file #{file}: #{e.message}")
    end
  end
end
