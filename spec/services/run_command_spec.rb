require 'rails_helper'

RSpec.describe RunCommand do
  describe '#call' do
    it 'returns the stdout when command is successful' do
      command_service = RunCommand.new([ "echo", "hello" ])
      result = command_service.call
      expect(result).to eq("hello\n")
    end

    it 'raises an error when command fails' do
      command_service = RunCommand.new([ "false" ])
      expect { command_service.call }.to raise_error(/Command failed with error/)
    end

    it 'passes environment variables to the command' do
      command_service = RunCommand.new(
        [ "/bin/sh", "-c", "echo $TEST_VAR" ],
        env: { "TEST_VAR" => "hello_from_env" }
      )
      result = command_service.call
      expect(result.strip).to eq("hello_from_env")
    end

    it 'writes output to log file when specified' do
      Dir.mktmpdir do |dir|
        log_path = File.join(dir, "test.log")
        command_service = RunCommand.new([ "echo", "logged output" ])
        command_service.call(log_file: log_path)
        expect(File.read(log_path)).to include("logged output")
      end
    end

    it 'sanitizes stderr in error messages to redact secrets' do
      command_service = RunCommand.new(
        [ "/bin/sh", "-c", "echo 'Error: invalid api_key=sk_live_abc123xyz' >&2; exit 1" ]
      )
      expect { command_service.call }.to raise_error do |error|
        expect(error.message).not_to include("sk_live_abc123xyz")
        expect(error.message).to include("[REDACTED]")
      end
    end

    it 'sanitizes stderr containing token values in error messages' do
      command_service = RunCommand.new(
        [ "/bin/sh", "-c", "echo 'auth failed: token=my_secret_token_123' >&2; exit 1" ]
      )
      expect { command_service.call }.to raise_error do |error|
        expect(error.message).not_to include("my_secret_token_123")
        expect(error.message).to include("[REDACTED]")
      end
    end

    it 'sanitizes stderr containing password values in error messages' do
      command_service = RunCommand.new(
        [ "/bin/sh", "-c", "echo 'connection failed: password=hunter2' >&2; exit 1" ]
      )
      expect { command_service.call }.to raise_error do |error|
        expect(error.message).not_to include("hunter2")
        expect(error.message).to include("[REDACTED]")
      end
    end
  end

  describe '#call_async' do
    it 'returns a process object' do
      command_service = RunCommand.new([ "echo", "async test" ])
      result = command_service.call_async
      expect(result).to be_a(Process::Waiter)
    end

    it 'passes environment variables to the async command' do
      Dir.mktmpdir do |dir|
        log_path = File.join(dir, "async.log")
        command_service = RunCommand.new(
          [ "/bin/sh", "-c", "echo $ASYNC_VAR" ],
          env: { "ASYNC_VAR" => "async_value" }
        )
        wait_thr = command_service.call_async(log_file: log_path)
        wait_thr.join
        # Wait for IO threads to flush after process exits
        sleep 1.0
        expect(File.read(log_path)).to include("async_value")
      end
    end

    it 'raises ImmediateExitError when process exits immediately with non-zero status' do
      command_service = RunCommand.new([ "/bin/sh", "-c", "exit 1" ])
      expect { command_service.call_async }.to raise_error(RunCommand::ImmediateExitError) do |error|
        expect(error.exit_status).to eq(1)
        expect(error.message).to include("exited immediately with status 1")
      end
    end

    it 'returns wait_thr when process exits immediately with zero status' do
      command_service = RunCommand.new([ "/bin/sh", "-c", "exit 0" ])
      result = command_service.call_async
      expect(result).to be_a(Process::Waiter)
    end

    it 'logs sanitized command and raises on immediate failure' do
      command_service = RunCommand.new(
        [ "/bin/sh", "-c", "exit 1", "--token", "super_secret_123" ],
      )
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:error)
      expect { command_service.call_async }.to raise_error(RunCommand::ImmediateExitError)
      expect(Rails.logger).to have_received(:error).with(/Command was:/).at_least(:once)
      expect(Rails.logger).not_to have_received(:error).with(/super_secret_123/)
    end
  end

  describe 'shell injection prevention' do
    it 'treats injection payloads as literal arguments, not shell commands' do
      payload = "'; rm -rf /; echo '"
      command_service = RunCommand.new([ "echo", payload ])
      result = command_service.call
      lines = result.strip.split("\n")
      expect(lines.length).to eq(1)
      expect(lines.first).to eq(payload)
    end

    it 'does not expand shell variables in arguments' do
      command_service = RunCommand.new([ "echo", "$HOME" ])
      result = command_service.call
      expect(result.strip).to eq("$HOME")
    end

    it 'does not interpret backticks in arguments' do
      command_service = RunCommand.new([ "echo", "`whoami`" ])
      result = command_service.call
      expect(result.strip).to eq("`whoami`")
    end

    it 'does not interpret subshell syntax in arguments' do
      command_service = RunCommand.new([ "echo", "$(whoami)" ])
      result = command_service.call
      expect(result.strip).to eq("$(whoami)")
    end

    it 'keeps secrets in env hash separate from logged command' do
      command_service = RunCommand.new(
        [ "echo", "test" ],
        env: { "SECRET_API_KEY" => "super_secret_value" }
      )
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("super_secret_value")
      expect(log_output).to include("echo test")
    end
  end

  describe 'sensitive argument redaction' do
    it 'redacts values following --token flag' do
      command_service = RunCommand.new([ "cmd", "--token", "sk_live_abc123" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("sk_live_abc123")
      expect(log_output).to include("--token [REDACTED]")
    end

    it 'redacts values following --password flag' do
      command_service = RunCommand.new([ "cmd", "--password", "hunter2" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("hunter2")
      expect(log_output).to include("--password [REDACTED]")
    end

    it 'redacts values following --api-key flag' do
      command_service = RunCommand.new([ "cmd", "--api-key", "key_abc123" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("key_abc123")
      expect(log_output).to include("--api-key [REDACTED]")
    end

    it 'redacts values following --secret flag' do
      command_service = RunCommand.new([ "cmd", "--secret", "mysecret" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("mysecret")
      expect(log_output).to include("--secret [REDACTED]")
    end

    it 'redacts values following --access-token flag' do
      command_service = RunCommand.new([ "cmd", "--access-token", "at_123" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("at_123")
      expect(log_output).to include("--access-token [REDACTED]")
    end

    it 'redacts values following --authorization flag' do
      command_service = RunCommand.new([ "cmd", "--authorization", "Bearer xyz" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("Bearer xyz")
      expect(log_output).to include("--authorization [REDACTED]")
    end

    it 'redacts --token=value inline format' do
      command_service = RunCommand.new([ "cmd", "--token=sk_live_abc123" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("sk_live_abc123")
      expect(log_output).to include("--token=[REDACTED]")
    end

    it 'redacts --api-key=value inline format' do
      command_service = RunCommand.new([ "cmd", "--api-key=key_abc123" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("key_abc123")
      expect(log_output).to include("--api-key=[REDACTED]")
    end

    it 'redacts --password=value inline format' do
      command_service = RunCommand.new([ "cmd", "--password=hunter2" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("hunter2")
      expect(log_output).to include("--password=[REDACTED]")
    end

    it 'does not redact non-sensitive flags' do
      command_service = RunCommand.new([ "cmd", "--verbose", "--output", "file.txt" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).to eq("cmd --verbose --output file.txt")
    end

    it 'handles single-dash sensitive flags' do
      command_service = RunCommand.new([ "cmd", "-token", "mysecret" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("mysecret")
      expect(log_output).to include("-token [REDACTED]")
    end

    it 'is case-insensitive for flag names' do
      command_service = RunCommand.new([ "cmd", "--TOKEN", "mysecret" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("mysecret")
      expect(log_output).to include("--TOKEN [REDACTED]")
    end

    it 'redacts values following --openai-api-key (partial match)' do
      command_service = RunCommand.new([ "cmd", "--openai-api-key", "sk-abc123" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("sk-abc123")
      expect(log_output).to include("--openai-api-key [REDACTED]")
    end

    it 'redacts values following --bearer-token (partial match)' do
      command_service = RunCommand.new([ "cmd", "--bearer-token", "bt_xyz" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("bt_xyz")
      expect(log_output).to include("--bearer-token [REDACTED]")
    end

    it 'redacts --openai-api-key=value inline format (partial match)' do
      command_service = RunCommand.new([ "cmd", "--openai-api-key=sk-abc123" ])
      log_output = command_service.send(:sanitize_for_logging)
      expect(log_output).not_to include("sk-abc123")
      expect(log_output).to include("--openai-api-key=[REDACTED]")
    end
  end

  describe 'output sanitization' do
    it 'redacts api_key values in output' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "Error: api_key=sk_live_abc123 is invalid")
      expect(result).not_to include("sk_live_abc123")
      expect(result).to include("[REDACTED]")
    end

    it 'redacts token values in output' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "failed: token=abc123xyz")
      expect(result).not_to include("abc123xyz")
      expect(result).to include("[REDACTED]")
    end

    it 'redacts password values in output' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "auth failed: password=hunter2")
      expect(result).not_to include("hunter2")
      expect(result).to include("[REDACTED]")
    end

    it 'redacts bearer token values in output' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "Authorization: Bearer eyJhbGciOiJSUzI1NiJ9")
      expect(result).not_to include("eyJhbGciOiJSUzI1NiJ9")
      expect(result).to include("[REDACTED]")
    end

    it 'redacts secret values with colon separator' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "secret: my_super_secret_value")
      expect(result).not_to include("my_super_secret_value")
      expect(result).to include("[REDACTED]")
    end

    it 'redacts credential values in output' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "credential=abc_def_123")
      expect(result).not_to include("abc_def_123")
      expect(result).to include("[REDACTED]")
    end

    it 'returns empty string for nil input' do
      command_service = RunCommand.new([ "echo", "test" ])
      expect(command_service.send(:sanitize_output, nil)).to eq("")
    end

    it 'returns empty string for empty input' do
      command_service = RunCommand.new([ "echo", "test" ])
      expect(command_service.send(:sanitize_output, "")).to eq("")
    end

    it 'truncates very long output' do
      command_service = RunCommand.new([ "echo", "test" ])
      long_text = "error: " + "x" * 600
      result = command_service.send(:sanitize_output, long_text)
      expect(result.length).to be <= 503
      expect(result).to end_with("...")
    end

    it 'preserves non-sensitive content in output' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "Error: file not found at /tmp/data.csv")
      expect(result).to eq("Error: file not found at /tmp/data.csv")
    end

    it 'handles multiple sensitive values in same output' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "api_key=abc123 token=xyz789")
      expect(result).not_to include("abc123")
      expect(result).not_to include("xyz789")
    end

    it 'redacts secrets in spaced equals format (key = value)' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "password = hunter2")
      expect(result).not_to include("hunter2")
      expect(result).to include("[REDACTED]")
    end

    it 'does not redact non-sensitive uses of token keyword' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "token estimation completed for 500 samples")
      expect(result).to eq("token estimation completed for 500 samples")
    end

    it 'skips truncation when truncate: false' do
      command_service = RunCommand.new([ "echo", "test" ])
      long_text = "info: " + "x" * 600
      result = command_service.send(:sanitize_output, long_text, truncate: false)
      expect(result.length).to eq(long_text.length)
      expect(result).not_to end_with("...")
    end

    it 'redacts JSON-quoted secret keys' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, '{"token":"abc123"}')
      expect(result).not_to include("abc123")
      expect(result).to include("[REDACTED]")
    end

    it 'redacts JSON-quoted secret keys with spaces' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, '{"api_key": "sk_live_abc123"}')
      expect(result).not_to include("sk_live_abc123")
      expect(result).to include("[REDACTED]")
    end

    it 'preserves JSON structure after redacting secrets' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, '{"token":"abc","error":"timeout"}')
      expect(result).not_to include("abc")
      expect(result).to include("timeout")
      expect(result).to include('"error"')
    end

    it 'redacts DATABASE_URL values in output' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "DATABASE_URL=postgresql://user:pass@host/db")
      expect(result).not_to include("postgresql://user:pass@host/db")
      expect(result).to include("[REDACTED]")
    end

    it 'redacts REDIS_URL values in output' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "REDIS_URL=redis://:secret@redis:6379/0")
      expect(result).not_to include("redis://:secret@redis:6379/0")
      expect(result).to include("[REDACTED]")
    end

    it 'redacts SECRET_KEY_BASE values in output' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "SECRET_KEY_BASE=abc123def456")
      expect(result).not_to include("abc123def456")
      expect(result).to include("[REDACTED]")
    end

    it 'redacts non-Bearer authorization schemes' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "Authorization: Splunk abc123def")
      expect(result).not_to include("abc123def")
      expect(result).to include("[REDACTED]")
    end

    it 'preserves ampersand-delimited context after secret values' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "token=abc123&code=401")
      expect(result).not_to include("abc123")
      expect(result).to include("[REDACTED]")
      expect(result).to include("&code=401")
    end

    it 'preserves semicolon-delimited context after secret values' do
      command_service = RunCommand.new([ "echo", "test" ])
      result = command_service.send(:sanitize_output, "access_token=abc123;error=timeout")
      expect(result).not_to include("abc123")
      expect(result).to include("[REDACTED]")
      expect(result).to include(";error=timeout")
    end
  end
end
