class RunCommand
  class ImmediateExitError < StandardError
    attr_reader :exit_status

    def initialize(exit_status, command_desc)
      @exit_status = exit_status
      super("Process exited immediately with status #{exit_status}: #{command_desc}")
    end
  end

  # Brief sleep to detect immediate process failures after launch.
  PROCESS_START_DETECTION_DELAY = 0.5
  REDACTED = "[REDACTED]"
  SENSITIVE_FLAG_NAME = /\b(api[_-]?key|token|password|secret|access[_-]?token|auth[_-]?token|credential|authorization|bearer)\b/i
  SENSITIVE_OUTPUT_PATTERN = /((?:api[_-]?key|token|password|secret|access[_-]?token|auth[_-]?token|credential|bearer|authorization|database[_-]?url|redis[_-]?url|secret[_-]?key[_-]?base)["']?\s*[=:]\s*["']?(?:(?:bearer|basic|splunk|negotiate|digest|token|bot)\s+)?)[^\s"',}\]&;]+/i

  attr_reader :command, :env

  def initialize(command, env: {})
    @command = command
    @env = env
  end

  def call(log_file: nil)
    stdout, stderr, status = Open3.capture3(env, *command)

    if log_file
      FileUtils.mkdir_p(File.dirname(log_file))
      File.open(log_file, "a") do |f|
        f.write(sanitize_output(stdout, truncate: false))
        f.write(sanitize_output(stderr, truncate: false))
      end
    end

    raise "Command failed with error: #{sanitize_output(stderr)}" unless status.success?

    stdout
  end

  def call_async(log_file: nil)
    Rails.logger.info("RunCommand.call_async executing: #{sanitize_for_logging}")

    stdin, stdout, stderr, wait_thr = Open3.popen3(env, *command)
    stdin.close

    log_io = if log_file
      FileUtils.mkdir_p(File.dirname(log_file))
      File.open(log_file, "a")
    end

    stdout_thread = Thread.new do
      begin
        stdout.each_line do |line|
          Rails.logger.info("Process: #{sanitize_output(line.chomp)}")
          if log_io
            log_io.write(sanitize_output(line, truncate: false))
            log_io.flush
          end
        end
      rescue => e
        Rails.logger.error("Error reading stdout: #{e.message}")
      ensure
        stdout.close
      end
    end

    stderr_thread = Thread.new do
      begin
        stderr.each_line do |line|
          Rails.logger.error("Process stderr: #{sanitize_output(line.chomp)}")
          if log_io
            log_io.write(sanitize_output(line, truncate: false))
            log_io.flush
          end
        end
      rescue => e
        Rails.logger.error("Error reading stderr: #{e.message}")
      ensure
        stderr.close
      end
    end

    if log_io
      Thread.new do
        stdout_thread.join
        stderr_thread.join
        log_io.close
      end
    end

    sleep PROCESS_START_DETECTION_DELAY
    if wait_thr.status == false || wait_thr.status.nil?
      exit_status = wait_thr.value.exitstatus
      if exit_status != 0
        Rails.logger.error("Process exited immediately with status: #{exit_status}")
        Rails.logger.error("Command was: #{sanitize_for_logging}")
        stdout_thread.join(2)
        stderr_thread.join(2)
        raise ImmediateExitError.new(exit_status, sanitize_for_logging)
      end
    else
      Rails.logger.info("Process started successfully with PID: #{wait_thr.pid}")
    end

    wait_thr
  end

  private

  def sanitize_for_logging
    sanitized = redact_sensitive_args(command)
    cmd_str = sanitized.join(" ")
    cmd_str.length > 300 ? "#{cmd_str[0..297]}..." : cmd_str
  end

  def sanitize_output(text, truncate: true)
    return "" if text.nil? || text.empty?
    sanitized = text.gsub(SENSITIVE_OUTPUT_PATTERN, "\\1#{REDACTED}")
    return sanitized unless truncate
    sanitized.length > 500 ? "#{sanitized[0..497]}..." : sanitized
  end

  def redact_sensitive_args(args)
    result = []
    redact_next = false
    args.each do |arg|
      if redact_next
        result << REDACTED
        redact_next = false
      elsif (m = arg.match(/\A(--[\w-]+)=(.+)\z/))
        flag_name = m[1].sub(/\A--/, "")
        if SENSITIVE_FLAG_NAME.match?(flag_name)
          result << "#{m[1]}=#{REDACTED}"
        else
          result << arg
        end
      elsif sensitive_flag?(arg)
        result << arg
        redact_next = true
      else
        result << arg
      end
    end
    result
  end

  def sensitive_flag?(arg)
    name = arg.sub(/\A-{1,2}/, "")
    SENSITIVE_FLAG_NAME.match?(name)
  end
end
