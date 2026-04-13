require 'rails_helper'
require 'logging'

RSpec.describe ValidateTarget, type: :service do
  let(:target) { create(:target, model_type: 'OpenAIGenerator', model: 'gpt-4', json_config: '{"test": "config"}') }
  let(:service) { described_class.new(target) }

  describe '#initialize' do
    it 'sets the target attribute' do
      expect(service.target).to eq(target)
    end
  end

  describe '#call' do
    let(:mock_run_command) { instance_double(RunCommand) }
    let(:validation_uuid) { 'validation_123_abc123' }
    let(:logger) { instance_double(ActiveSupport::Logger) }

    before do
      allow(service).to receive(:validation_uuid).and_return(validation_uuid)
      allow(RunCommand).to receive(:new).and_return(mock_run_command)
      allow(mock_run_command).to receive(:call)
      allow(service).to receive(:process_validation_result)
      # Actually create directories needed for file operations
      FileUtils.mkdir_p(described_class::CONFIG_PATH)
      FileUtils.mkdir_p(described_class::LOGS_PATH)
      allow(Rails).to receive(:logger).and_return(logger)
      allow(logger).to receive(:info)
      allow(logger).to receive(:error)
    end

    after do
      # Cleanup any created config files
      config_file = described_class::CONFIG_PATH.join("#{validation_uuid}.json")
      File.delete(config_file) if File.exist?(config_file)
    end

    context 'with webchat target' do
      let(:web_config) do
        {
          "url" => "https://example.com/chat",
          "selectors" => {
            "input_field" => "#chat-input",
            "response_container" => ".chat-messages"
          }
        }
      end
      let(:webchat_target) { create(:target, target_type: :webchat, web_config: web_config) }
      let(:webchat_service) { described_class.new(webchat_target) }
      let(:validate_web_chat_service) { instance_double(ValidateWebChatTarget) }

      it 'delegates to ValidateWebChatTarget' do
        expect(ValidateWebChatTarget).to receive(:new).with(webchat_target).and_return(validate_web_chat_service)
        expect(validate_web_chat_service).to receive(:call)

        webchat_service.call
      end

      it 'does not call RunCommand for webchat targets' do
        allow(ValidateWebChatTarget).to receive(:new).and_return(validate_web_chat_service)
        allow(validate_web_chat_service).to receive(:call)

        expect(RunCommand).not_to receive(:new)

        webchat_service.call
      end
    end

    context 'with API target' do
      it 'uses RunCommand for API targets' do
        expect(RunCommand).to receive(:new).with(kind_of(Array), env: kind_of(Hash)).and_return(mock_run_command)
        expect(mock_run_command).to receive(:call).with(log_file: kind_of(String))

        service.call
      end

      it 'does not call ValidateWebChatTarget for API targets' do
        expect(ValidateWebChatTarget).not_to receive(:new)

        service.call
      end
    end

    it 'updates target status to validating at start' do
      # Allow other updates but expect validating specifically
      allow(target).to receive(:update)
      expect(target).to receive(:update).with(status: :validating).once

      service.call
    end

    it 'creates and calls RunCommand with argv array and env hash' do
      expect(RunCommand).to receive(:new).with(kind_of(Array), env: kind_of(Hash)).and_return(mock_run_command)
      expect(mock_run_command).to receive(:call).with(log_file: kind_of(String))

      service.call
    end

    it 'processes the validation result' do
      expect(service).to receive(:process_validation_result)

      service.call
    end

    it 'logs validation start with context' do
      expect(logger).to receive(:info).with("validation.started")
      expect(logger).to receive(:info).with("validation.invoking")

      service.call
    end

    context 'when an error occurs during execution' do
      let(:error_message) { 'Command execution failed' }
      let(:error) { StandardError.new(error_message) }

      before do
        allow(mock_run_command).to receive(:call).and_raise(error)
        allow(Rails.logger).to receive(:error)
      end

      it 'logs the error with structured context' do
        expect(logger).to receive(:error).with("validation.error")

        service.call
      end

      it 'updates target status to bad with error message' do
        service.call

        target.reload
        expect(target.status).to eq('bad')
        expect(target.validation_text).to eq("Validation failed: #{error_message}")
      end
    end
  end

  describe 'private methods' do
    let(:validation_uuid) { 'validation_123_abc123' }

    before do
      allow(service).to receive(:validation_uuid).and_return(validation_uuid)
    end

    describe '#build_argv' do
      it 'returns a flat array with python, script path, uuid, and individual params' do
        argv = service.send(:build_argv)

        expect(argv).to be_an(Array)
        expect(argv[0]).to eq("/opt/venv/bin/python3")
        expect(argv[1]).to include("run_garak.py")
        expect(argv[2]).to eq(validation_uuid)
        expect(argv[3]).to eq("--target_type")
        expect(argv[4]).to include("OpenAIGenerator")
        expect(argv[5]).to eq("--target_name")
        expect(argv[6]).to eq("gpt-4")
      end
    end

    describe '#build_env' do
      let!(:global_env_var) { create(:environment_variable, target: nil, env_name: 'API_KEY', env_value: 'secret') }
      let!(:excluded_env_var) { create(:environment_variable, target: nil, env_name: 'EVALUATION_THRESHOLD', env_value: '0.5') }

      it 'returns a hash of environment variables' do
        env = service.send(:build_env)

        expect(env).to be_a(Hash)
        expect(env["HOME"]).to eq("/home/rails")
      end

      it 'includes global environment variables' do
        env = service.send(:build_env)
        expect(env["API_KEY"]).to eq("secret")
      end

      it 'excludes EVALUATION_THRESHOLD' do
        env = service.send(:build_env)
        expect(env).not_to have_key("EVALUATION_THRESHOLD")
      end

      it 'preserves values verbatim without shell escaping' do
        create(:environment_variable, target: nil, env_name: 'INJECTION_TEST', env_value: 'value; rm -rf /')

        env = service.send(:build_env)
        expect(env["INJECTION_TEST"]).to eq('value; rm -rf /')
      end

      it 'preserves values with special shell characters' do
        create(:environment_variable, target: nil, env_name: 'SPECIAL_CHARS', env_value: "val'ue $(whoami)")

        env = service.send(:build_env)
        expect(env["SPECIAL_CHARS"]).to eq("val'ue $(whoami)")
      end
    end

    describe '#params' do
      it 'returns a flat array of individual arguments' do
        allow(service).to receive(:temp_json_file_path).and_return('/path/to/config.json')

        params = service.send(:params)

        expect(params).to be_an(Array)
        expect(params).to include("--target_type", "--target_name", "--probes", "--report_prefix", "--generator_option_file")
        expect(params).not_to include(nil)
        params.each { |p| expect(p).to be_a(String) }
      end
    end

    describe '#target_type_arg' do
      it 'returns a two-element array with flag and value' do
        target_type = service.send(:target_type_arg)
        expect(target_type).to eq([ "--target_type", "openai.OpenAIGenerator" ])
      end
    end

    describe '#target_name_arg' do
      it 'returns a two-element array with flag and value' do
        target_name = service.send(:target_name_arg)
        expect(target_name).to eq([ "--target_name", "gpt-4" ])
      end
    end

    describe '#probe' do
      it 'returns a two-element array with flag and value' do
        probe = service.send(:probe)
        expect(probe).to eq([ "--probes", Scanner.configuration.validation_probe ])
      end
    end

    describe '#generator_options' do
      context 'when target has json_config' do
        before do
          allow(service).to receive(:temp_json_file_path).and_return('/path/to/config.json')
        end

        it 'returns a two-element array with flag and path' do
          generator_options = service.send(:generator_options)
          expect(generator_options).to eq([ "--generator_option_file", "/path/to/config.json" ])
        end
      end

      context 'when target has no json_config' do
        let(:target) { create(:target, json_config: nil) }

        it 'returns nil' do
          generator_options = service.send(:generator_options)
          expect(generator_options).to be_nil
        end
      end
    end

    describe '#temp_json_file_path' do
      before do
        allow(FileUtils).to receive(:mkdir_p)
        allow(File).to receive(:write)
      end

      it 'creates config directory and writes JSON file' do
        expect(Dir).to receive(:exist?).with(described_class::CONFIG_PATH).and_return(false)
        expect(FileUtils).to receive(:mkdir_p).with(described_class::CONFIG_PATH)
        expect(File).to receive(:write).with(
          described_class::CONFIG_PATH.join("#{validation_uuid}.json"),
          target.json_config
        )

        service.send(:temp_json_file_path)
      end

      it 'returns the correct file path' do
        file_path = service.send(:temp_json_file_path)
        expect(file_path).to eq(described_class::CONFIG_PATH.join("#{validation_uuid}.json").to_s)
      end

      context 'when file creation fails' do
        let(:error) { StandardError.new('Permission denied') }

        before do
          allow(File).to receive(:write).and_raise(error)
          allow(Rails.logger).to receive(:error)
        end

        it 'logs error and re-raises' do
          expect(Rails.logger).to receive(:error).with('Failed to create JSON config file: Permission denied')
          expect { service.send(:temp_json_file_path) }.to raise_error(StandardError, 'Permission denied')
        end
      end
    end
  end

  describe '#process_validation_result' do
    let(:validation_uuid) { 'validation_123_abc123' }
    let(:jsonl_file_path) { described_class::VALIDATION_REPORTS_PATH.join("#{validation_uuid}.report.jsonl") }
    let(:logger) { instance_double(ActiveSupport::Logger) }

    before do
      allow(service).to receive(:validation_uuid).and_return(validation_uuid)
      allow(service).to receive(:cleanup_validation_files)
      allow(Rails).to receive(:logger).and_return(logger)
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:error)
    end

    context 'when report file does not exist' do
      before do
        allow(File).to receive(:exist?).with(jsonl_file_path).and_return(false)
      end

      it 'updates target status to bad with appropriate message' do
        service.send(:process_validation_result)

        target.reload
        expect(target.status).to eq('bad')
        expect(target.validation_text).to eq('Validation report file not found')
      end
    end

    context 'when report file exists with successful responses' do
      let(:jsonl_content) do
        [
          '{"entry_type": "attempt", "outputs": ["Response 1", "Response 2"]}',
          '{"entry_type": "attempt", "outputs": ["Another response"]}',
          '{"entry_type": "eval", "passed": 2, "total": 3}'
        ]
      end

      before do
        content_lines = jsonl_content
        file_mock = instance_double(File)

        allow(file_mock).to receive(:each).and_yield(content_lines[0]).and_yield(content_lines[1])
                                          .and_yield(content_lines[2])

        allow(File).to receive(:exist?).with(jsonl_file_path).and_return(true)
        allow(File).to receive(:open).with(jsonl_file_path, 'r').and_return(file_mock)
      end

      it 'updates target status to good with success message' do
        service.send(:process_validation_result)

        target.reload
        expect(target.status).to eq('good')
        expect(target.validation_text).to include('Target validated successfully - received 2 response(s)')
        expect(target.validation_text).to include('Sample response: Response 1')
        expect(target.validation_text).to include('Evaluation: 2/3 attempts passed')
      end

      it 'logs validation completion with structured context' do
        expect(logger).to receive(:info).with("validation.result.valid")

        service.send(:process_validation_result)
      end
    end

    context 'when report file exists with no responses' do
      let(:jsonl_content) do
        [
          '{"entry_type": "attempt", "outputs": []}',
          '{"entry_type": "attempt", "outputs": ["", "  "]}',
          '{"entry_type": "eval", "passed": 0, "total": 2}'
        ]
      end

      before do
        content_lines = jsonl_content
        file_mock = instance_double(File)

        allow(file_mock).to receive(:each).and_yield(content_lines[0]).and_yield(content_lines[1])
                                          .and_yield(content_lines[2])

        allow(File).to receive(:exist?).with(jsonl_file_path).and_return(true)
        allow(File).to receive(:open).with(jsonl_file_path, 'r').and_return(file_mock)
        allow(Rails.logger).to receive(:warn)
      end

      it 'updates target status to bad with failure message' do
        service.send(:process_validation_result)

        target.reload
        expect(target.status).to eq('bad')
        expect(target.validation_text).to include('Target validation failed: No responses received')
        expect(target.validation_text).to include('Evaluation: 0/2 attempts passed')
      end

      it 'logs a warning with structured context' do
        expect(logger).to receive(:warn).with("validation.result.invalid")

        service.send(:process_validation_result)
      end
    end
  end

  describe '#cleanup_validation_files' do
    let(:validation_uuid) { 'validation_123_abc123' }
    let(:config_file) { described_class::CONFIG_PATH.join("#{validation_uuid}.json") }
    let(:log_file) { described_class::LOGS_PATH.join("#{validation_uuid}.log") }
    let(:report_file) { described_class::VALIDATION_REPORTS_PATH.join("#{validation_uuid}.report.jsonl") }

    before do
      allow(service).to receive(:validation_uuid).and_return(validation_uuid)
    end

    context 'when all files exist' do
      before do
        allow(File).to receive(:exist?).and_return(true)
        allow(File).to receive(:delete)
      end

      it 'deletes all validation files' do
        expect(File).to receive(:delete).with(config_file)
        expect(File).to receive(:delete).with(log_file)
        expect(File).to receive(:delete).with(report_file)

        service.send(:cleanup_validation_files)
      end
    end

    context 'when file deletion fails' do
      before do
        allow(File).to receive(:exist?).and_return(true)
        allow(File).to receive(:delete).with(config_file).and_raise(StandardError.new('Permission denied'))
        allow(File).to receive(:delete).with(log_file)
        allow(File).to receive(:delete).with(report_file)
        allow(Rails.logger).to receive(:warn)
      end

      it 'logs warning but continues with other files' do
        expect(Rails.logger).to receive(:warn).with("Failed to cleanup validation file #{config_file}: Permission denied")
        expect(File).to receive(:delete).with(log_file)
        expect(File).to receive(:delete).with(report_file)

        service.send(:cleanup_validation_files)
      end
    end
  end

  describe 'token rate measurement during validation' do
    let(:validation_uuid) { 'validation_123_abc123' }
    let(:jsonl_file_path) { described_class::VALIDATION_REPORTS_PATH.join("#{validation_uuid}.report.jsonl") }
    let(:logger) { instance_double(ActiveSupport::Logger) }

    before do
      allow(service).to receive(:validation_uuid).and_return(validation_uuid)
      allow(service).to receive(:cleanup_validation_files)
      allow(Rails).to receive(:logger).and_return(logger)
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:error)
    end

    describe '#calculate_tokens_per_second' do
      before do
        # Simulate validation_start_time being set
        service.instance_variable_set(:@validation_start_time, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10.0)
      end

      it 'calculates tokens per second from output tokens and duration' do
        result = service.send(:calculate_tokens_per_second, 500)

        expect(result).to be_a(Float)
        expect(result).to be > 0
        # 500 tokens / ~10 seconds = ~50 tok/s
        expect(result).to be_within(10).of(50)
      end

      it 'returns nil when validation_start_time is not set' do
        service.instance_variable_set(:@validation_start_time, nil)

        result = service.send(:calculate_tokens_per_second, 500)

        expect(result).to be_nil
      end

      it 'returns nil when total_output_tokens is zero' do
        result = service.send(:calculate_tokens_per_second, 0)

        expect(result).to be_nil
      end

      it 'returns nil when total_output_tokens is negative' do
        result = service.send(:calculate_tokens_per_second, -100)

        expect(result).to be_nil
      end

      it 'rounds result to 2 decimal places' do
        # Set a specific timing for predictable result
        service.instance_variable_set(:@validation_start_time, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 3.0)

        result = service.send(:calculate_tokens_per_second, 100)

        expect(result.to_s).to match(/^\d+\.?\d{0,2}$/)
      end
    end

    describe '#process_validation_result with token rate measurement' do
      context 'when validation succeeds with responses' do
        let(:jsonl_content) do
          [
            '{"entry_type": "attempt", "outputs": ["Hello, how can I help you today?", "I am an AI assistant."]}',
            '{"entry_type": "attempt", "outputs": ["Sure, I can help with that question."]}',
            '{"entry_type": "eval", "passed": 3, "total": 3}'
          ]
        end

        before do
          content_lines = jsonl_content
          file_mock = instance_double(File)
          allow(file_mock).to receive(:each)
            .and_yield(content_lines[0])
            .and_yield(content_lines[1])
            .and_yield(content_lines[2])

          allow(File).to receive(:exist?).with(jsonl_file_path).and_return(true)
          allow(File).to receive(:open).with(jsonl_file_path, 'r').and_return(file_mock)

          # Mock validation timing
          service.instance_variable_set(:@validation_start_time, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 5.0)

          # Allow TokenEstimator calls
          allow(TokenEstimator).to receive(:estimate_tokens).and_return(50)
        end

        it 'stores tokens_per_second on successful validation' do
          service.send(:process_validation_result)

          target.reload
          expect(target.status).to eq('good')
          expect(target.tokens_per_second).to be_present
          expect(target.tokens_per_second).to be > 0
        end

        it 'sets tokens_per_second_sample_count to 1 on first measurement' do
          service.send(:process_validation_result)

          target.reload
          expect(target.tokens_per_second_sample_count).to eq(1)
        end
      end

      context 'when validation fails with no responses' do
        let(:jsonl_content) do
          [
            '{"entry_type": "attempt", "outputs": []}',
            '{"entry_type": "eval", "passed": 0, "total": 3}'
          ]
        end

        before do
          content_lines = jsonl_content
          file_mock = instance_double(File)
          allow(file_mock).to receive(:each)
            .and_yield(content_lines[0])
            .and_yield(content_lines[1])

          allow(File).to receive(:exist?).with(jsonl_file_path).and_return(true)
          allow(File).to receive(:open).with(jsonl_file_path, 'r').and_return(file_mock)
          allow(Rails.logger).to receive(:warn)

          service.instance_variable_set(:@validation_start_time, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 5.0)
        end

        it 'does not store tokens_per_second on failed validation' do
          service.send(:process_validation_result)

          target.reload
          expect(target.status).to eq('bad')
          expect(target.tokens_per_second).to be_nil
        end
      end
    end
  end
end
