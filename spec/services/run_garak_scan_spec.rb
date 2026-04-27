require 'rails_helper'

RSpec.describe RunGarakScan, type: :service do
  describe '#initialize' do
    it 'sets the report attribute' do
      report = build(:report)
      service = described_class.new(report)
      expect(service.report).to eq(report)
    end
  end

  describe '#call' do
    let(:target) { create(:target, :good, model_type: 'OpenAIGenerator', model: 'gpt-4') }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan) }

    before do
      allow(FileUtils).to receive(:mkdir_p)
    end

    it 'updates the report status to starting' do
      service = described_class.new(report)
      allow(service).to receive(:call).and_call_original
      allow(service).to receive(:execute_scan)

      expect(report).to receive(:update).with(status: :starting)

      service.call
    end

    it 'calls execute_scan for valid targets' do
      service = described_class.new(report)
      allow(service).to receive(:call).and_call_original

      expect(service).to receive(:execute_scan)
      expect(report).to receive(:update).with(status: :starting)

      service.call
    end

    it 'fails the report if target has bad status' do
      bad_target = create(:target, :bad)
      bad_report = build(:report, target: bad_target, scan: scan)
      bad_report.save(validate: false) # Skip validation to test the service logic

      service = described_class.new(bad_report)

      # Override the global stub for this test
      allow(service).to receive(:call).and_call_original
      allow(Rails.logger).to receive(:error)

      expect(Rails.logger).to receive(:error).with("Cannot run scan for report #{bad_report.id} - target #{bad_target.id} (#{bad_target.name}) has 'bad' status. Validation text: #{bad_target.validation_text}")
      expect(bad_report).to receive(:update).with(
        status: :failed,
        logs: "Scan failed: Target '#{bad_target.name}' validation failed. #{bad_target.validation_text}"
      )

      service.call
    end

    it 'fails the report if target has bad status without validation text' do
      bad_target = create(:target, status: :bad, validation_text: nil)
      bad_report = build(:report, target: bad_target, scan: scan)
      bad_report.save(validate: false) # Skip validation to test the service logic

      service = described_class.new(bad_report)

      # Override the global stub for this test
      allow(service).to receive(:call).and_call_original
      allow(Rails.logger).to receive(:error)

      expect(Rails.logger).to receive(:error).with("Cannot run scan for report #{bad_report.id} - target #{bad_target.id} (#{bad_target.name}) has 'bad' status. Validation text: ")
      expect(bad_report).to receive(:update).with(
        status: :failed,
        logs: "Scan failed: Target '#{bad_target.name}' validation failed."
      )

      service.call
    end

    it 'proceeds normally for targets with good status' do
      good_target = create(:target, :good)
      good_report = create(:report, target: good_target, scan: scan)

      service = described_class.new(good_report)

      allow(service).to receive(:call).and_call_original
      allow(service).to receive(:execute_scan)

      expect(good_report).to receive(:update).with(status: :starting)

      service.call
    end

    it 'fails the report if target has validating status' do
      validating_target = create(:target, :validating)
      validating_report = create(:report, target: validating_target, scan: scan)

      service = described_class.new(validating_report)

      # Override the global stub for this test
      allow(service).to receive(:call).and_call_original
      allow(Rails.logger).to receive(:warn)

      expect(Rails.logger).to receive(:warn).with("Cannot run scan for report #{validating_report.id} - target #{validating_target.id} (#{validating_target.name}) is in 'validating' status")
      expect(validating_report).to receive(:update).with(
        status: :failed,
        logs: "Scan failed: Target '#{validating_target.name}' is still being validated. Please wait for validation to complete before running scans."
      )

      service.call
    end

    it 'handles unexpected target status gracefully' do
      # Simulate an unexpected status by stubbing the status method
      unexpected_target = create(:target, :good)
      unexpected_report = create(:report, target: unexpected_target, scan: scan)

      allow(unexpected_target).to receive(:status).and_return("unknown_status")

      service = described_class.new(unexpected_report)

      # Override the global stub for this test
      allow(service).to receive(:call).and_call_original
      allow(Rails.logger).to receive(:error)

      expect(Rails.logger).to receive(:error).with("Cannot run scan for report #{unexpected_report.id} - target #{unexpected_target.id} (#{unexpected_target.name}) has unexpected status: unknown_status")
      expect(unexpected_report).to receive(:update).with(
        status: :failed,
        logs: "Scan failed: Target '#{unexpected_target.name}' is not ready for scanning (status: unknown_status). Target must be validated successfully before running scans."
      )

      service.call
    end
  end

  describe 'argv-based command construction' do
    let(:json_config) { '{"temperature": 0.7}' }
    let(:target) { create(:target, :good, model_type: 'OpenAIGenerator', model: 'gpt-4', json_config: json_config) }
    let(:scan) { create(:complete_scan, company: target.company) }
    let(:report) { create(:report, target: target, scan: scan, company: target.company) }

    before do
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:write)
      allow(Dir).to receive(:exist?).and_return(true)
    end

    describe '#build_argv' do
      it 'returns an array with python, script path, uuid, followed by individual params' do
        service = described_class.new(report)
        argv = service.send(:build_argv)

        expect(argv).to be_an(Array)
        expect(argv[0]).to eq("/opt/venv/bin/python3")
        expect(argv[1]).to include("run_garak.py")
        expect(argv[2]).to eq(report.uuid)
        expect(argv.length).to be > 3
        expect(argv.all? { |e| e.is_a?(String) }).to be true
      end

      it 'passes each flag and value as separate argv elements' do
        service = described_class.new(report)
        argv = service.send(:build_argv)

        expect(argv).to include("--skip_unknown")
        expect(argv).to include("--target_type")
        expect(argv).to include("--target_name")
      end

      it 'does not contain shell metacharacters in the argv structure' do
        service = described_class.new(report)
        argv = service.send(:build_argv)

        expect(argv[0]).not_to include("|")
        expect(argv[0]).not_to include(";")
        expect(argv[0]).not_to include("&&")
      end
    end

    describe '#build_env' do
      it 'returns a hash of environment variables' do
        service = described_class.new(report)

        ActsAsTenant.with_tenant(report.company) do
          env = service.send(:build_env)

          expect(env).to be_a(Hash)
          expect(env["HOME"]).to eq("/home/rails")
          expect(env["REPORT_UUID"]).to eq(report.uuid)
          expect(env["SCAN_ID"]).to eq(report.scan.id.to_s)
          expect(env["TARGET_ID"]).to eq(target.id.to_s)
        end
      end

      it 'includes DATABASE_URL' do
        service = described_class.new(report)

        ActsAsTenant.with_tenant(report.company) do
          env = service.send(:build_env)
          expect(env["DATABASE_URL"]).to be_present
        end
      end
    end

    it 'decrypts json_config within tenant context for generator options' do
      service = described_class.new(report)

      allow(RunCommand).to receive(:new).and_return(double(call_async: nil))

      expect {
        ActsAsTenant.with_tenant(report.company) do
          service.send(:generator_options)
        end
      }.not_to raise_error
    end
  end

  describe 'injection prevention' do
    let(:target) { create(:target, :good, model_type: 'OpenAIGenerator', model: 'gpt-4') }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan) }

    before do
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:write)
      allow(Dir).to receive(:exist?).and_return(true)
    end

    it 'constructs argv array that does not pass through shell' do
      service = described_class.new(report)
      argv = service.send(:build_argv)

      expect(argv).to be_an(Array)
      expect(argv.length).to be > 3
      expect(argv.all? { |e| e.is_a?(String) }).to be true
    end

    it 'passes env vars as a hash, not as shell-prefixed strings' do
      service = described_class.new(report)

      ActsAsTenant.with_tenant(report.company) do
        env = service.send(:build_env)

        expect(env).to be_a(Hash)
        env.each do |key, value|
          expect(key).to be_a(String)
          expect(value).to be_a(String)
        end
      end
    end
  end

  describe 'webchat functionality' do
    let(:web_config) do
      {
        "url" => "https://example.com/chat",
        "selectors" => {
          "input_field" => "#chat-input",
          "send_button" => "#send-btn",
          "response_container" => ".chat-messages"
        },
        "wait_times" => {
          "page_load" => 30000,
          "response" => 5000
        }
      }
    end

    let(:webchat_target) { create(:target, target_type: :webchat, web_config: web_config) }
    let(:scan) { create(:complete_scan) }
    let(:webchat_report) { create(:report, target: webchat_target, scan: scan) }
    let(:service) { described_class.new(webchat_report) }

    before do
      # Ensure config directory exists for tests that write files
      FileUtils.mkdir_p(described_class::CONFIG_PATH)
    end

    after do
      # Cleanup any created config files
      Dir.glob(described_class::CONFIG_PATH.join("#{webchat_report.uuid}*")).each do |f|
        File.delete(f) if File.exist?(f)
      end
    end

    describe '#params' do
      it 'calls web_chat_params for webchat targets' do
        expect(service).to receive(:web_chat_params).and_call_original
        service.send(:params)
      end

      it 'calls api_params for API targets' do
        api_target = create(:target, target_type: :api, model_type: 'OpenAIGenerator', model: 'gpt-4')
        api_report = create(:report, target: api_target, scan: scan)
        api_service = described_class.new(api_report)

        expect(api_service).to receive(:api_params).and_call_original
        api_service.send(:params)
      end
    end

    describe '#web_chat_params' do
      it 'includes web_chatbot target type' do
        params = service.send(:web_chat_params)
        expect(params).to include('--target_type', 'web_chatbot.WebChatbotGenerator')
      end

      it 'includes web_chatbot target name' do
        params = service.send(:web_chat_params)
        expect(params).to include('--target_name', 'web_chatbot')
      end

      it 'includes generator options file' do
        allow(service).to receive(:temp_web_config_file_path).and_return('/tmp/test_web.json')
        params = service.send(:web_chat_params)
        expect(params).to include('--generator_option_file', '/tmp/test_web.json')
      end

      it 'includes skip_unknown flag' do
        params = service.send(:web_chat_params)
        expect(params).to include('--skip_unknown')
      end

      it 'returns a flat array of strings' do
        params = service.send(:web_chat_params)
        expect(params).to be_an(Array)
        expect(params.all? { |e| e.is_a?(String) }).to be true
      end
    end

    describe '#web_chat_target_name' do
      it 'returns web_chatbot target name as array' do
        expect(service.send(:web_chat_target_name)).to eq([ '--target_name', 'web_chatbot' ])
      end
    end

    describe '#web_chat_generator_options' do
      it 'returns generator option file path as array when web_config is present' do
        allow(service).to receive(:temp_web_config_file_path).and_return('/tmp/test_web.json')
        expect(service.send(:web_chat_generator_options)).to eq([ '--generator_option_file', '/tmp/test_web.json' ])
      end

      it 'returns nil when web_config is blank' do
        webchat_target.update(web_config: nil)
        expect(service.send(:web_chat_generator_options)).to be_nil
      end
    end

    describe '#temp_web_config_file_path' do
      it 'creates a config file with garak structure' do
        file_path = service.send(:temp_web_config_file_path)

        expect(File.exist?(file_path)).to be true

        config = JSON.parse(File.read(file_path))
        expect(config).to have_key('web_chatbot')
        expect(config['web_chatbot']).to have_key('WebChatbotGenerator')
        expect(config['web_chatbot']['WebChatbotGenerator']).to have_key('url')
        expect(config['web_chatbot']['WebChatbotGenerator']['url']).to eq('https://example.com/chat')
      end

      it 'handles web_config as JSON string' do
        webchat_target.update(web_config: web_config.to_json)
        file_path = service.send(:temp_web_config_file_path)

        expect(File.exist?(file_path)).to be true

        config = JSON.parse(File.read(file_path))
        expect(config['web_chatbot']['WebChatbotGenerator']['url']).to eq('https://example.com/chat')
      end

      it 'ensures config directory exists' do
        FileUtils.rm_rf(described_class::CONFIG_PATH)
        expect(Dir.exist?(described_class::CONFIG_PATH)).to be false

        service.send(:temp_web_config_file_path)

        expect(Dir.exist?(described_class::CONFIG_PATH)).to be true
      end

      it 'raises error if config file creation fails' do
        allow(File).to receive(:write).and_raise(StandardError, 'Disk full')
        expect(Rails.logger).to receive(:error).with('Failed to create web config file: Disk full')

        expect {
          service.send(:temp_web_config_file_path)
        }.to raise_error(StandardError, 'Disk full')
      end
    end
  end

  describe 'scan resumption' do
    let(:target) { create(:target, :good) }
    let(:probe1) { create(:probe, name: 'test.ProbeA') }
    let(:probe2) { create(:probe, name: 'test.ProbeB') }
    let(:scan) do
      s = build(:scan)
      s.targets << target
      s.probes << probe1
      s.probes << probe2
      s.save!(validate: false)
      s
    end
    let(:report) { create(:report, target: target, scan: scan) }

    before do
      allow(FileUtils).to receive(:mkdir_p)
    end

    context 'when no previous run data exists' do
      it 'includes all probes' do
        service = described_class.new(report)
        remaining = service.send(:remaining_probes)
        expect(remaining).to contain_exactly('test.ProbeA', 'test.ProbeB')
      end

      it 'returns false for all_probes_completed?' do
        service = described_class.new(report)
        expect(service.send(:all_probes_completed?)).to be false
      end
    end

    context 'when partial JSONL data exists with one completed probe' do
      let(:partial_jsonl) do
        [
          { entry_type: 'init', start_time: '2024-01-01T00:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: 'test.ProbeA', uuid: 'a1', prompt: 'test', outputs: [ 'out' ] }.to_json,
          { entry_type: 'eval', probe: 'test.ProbeA', detector: 'detector.test', passed: 3, total_evaluated: 10 }.to_json
        ].join("\n")
      end

      before do
        create(:raw_report_data, report: report, jsonl_data: partial_jsonl)
      end

      it 'filters out the completed probe' do
        service = described_class.new(report)
        remaining = service.send(:remaining_probes)
        expect(remaining).to eq([ 'test.ProbeB' ])
      end

      it 'logs resumption info' do
        service = described_class.new(report)
        expect(Rails.logger).to receive(:info).with(/Resuming scan.*1\/2 probes already completed/)
        service.send(:remaining_probes)
      end
    end

    context 'when partial JSONL data contains only legacy total eval rows' do
      let(:legacy_jsonl) do
        [
          { entry_type: 'init', start_time: '2024-01-01T00:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: 'test.ProbeA', uuid: 'a1', prompt: 'test', outputs: [ 'out' ] }.to_json,
          { entry_type: 'eval', probe: 'test.ProbeA', detector: 'detector.test', passed: 3, total: 10 }.to_json
        ].join("\n")
      end

      before do
        create(:raw_report_data, report: report, jsonl_data: legacy_jsonl)
      end

      it 'does not mark the probe completed' do
        service = described_class.new(report)
        expect(service.send(:remaining_probes)).to contain_exactly('test.ProbeA', 'test.ProbeB')
      end
    end

    context 'when all probes already completed' do
      let(:full_jsonl) do
        [
          { entry_type: 'init', start_time: '2024-01-01T00:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: 'test.ProbeA', uuid: 'a1', prompt: 'test', outputs: [ 'out' ] }.to_json,
          { entry_type: 'eval', probe: 'test.ProbeA', detector: 'detector.test', passed: 3, total_evaluated: 10 }.to_json,
          { entry_type: 'attempt', probe_classname: 'test.ProbeB', uuid: 'a2', prompt: 'test', outputs: [ 'out' ] }.to_json,
          { entry_type: 'eval', probe: 'test.ProbeB', detector: 'detector.test', passed: 5, total_evaluated: 10 }.to_json,
          { entry_type: 'completion', end_time: '2024-01-01T01:00:00Z' }.to_json
        ].join("\n")
      end

      before do
        create(:raw_report_data, report: report, jsonl_data: full_jsonl)
      end

      it 'detects all probes as completed' do
        service = described_class.new(report)
        expect(service.send(:all_probes_completed?)).to be true
      end

      it 'enqueues ProcessReportJob directly without running garak' do
        # spec/support/run_garak_scan_stub.rb globally stubs RunGarakScan#call.
        # Override here to test the real implementation path.
        allow_any_instance_of(RunGarakScan).to receive(:call).and_call_original

        service = described_class.new(report)

        expect(ProcessReportJob).to receive(:perform_later).with(report.id)
        expect(service).not_to receive(:execute_scan)

        service.call
      end
    end

    context 'when JSONL contains malformed JSON lines' do
      let(:messy_jsonl) do
        [
          { entry_type: 'init', start_time: '2024-01-01T00:00:00Z' }.to_json,
          'this is not valid json {{{',
          { entry_type: 'eval', probe: 'test.ProbeA', detector: 'detector.test', passed: 3, total_evaluated: 10 }.to_json,
          '{"entry_type": "eval", "probe": ',
          { entry_type: 'eval', probe: 'test.ProbeB', detector: 'detector.test', passed: 5, total_evaluated: 10 }.to_json
        ].join("\n")
      end

      before do
        create(:raw_report_data, report: report, jsonl_data: messy_jsonl)
      end

      it 'skips malformed lines and parses valid ones' do
        service = described_class.new(report)
        completed = service.send(:completed_probes_from_raw_data)
        expect(completed).to contain_exactly('test.ProbeA', 'test.ProbeB')
      end
    end

    context 'when completed_probes_from_raw_data is called multiple times' do
      let(:partial_jsonl) do
        [
          { entry_type: 'eval', probe: 'test.ProbeA', detector: 'detector.test', passed: 3, total_evaluated: 10 }.to_json
        ].join("\n")
      end

      before do
        create(:raw_report_data, report: report, jsonl_data: partial_jsonl)
      end

      it 'memoizes the result' do
        service = described_class.new(report)
        result1 = service.send(:completed_probes_from_raw_data)
        result2 = service.send(:completed_probes_from_raw_data)
        expect(result1).to equal(result2) # same object identity
      end
    end

    context 'when JSONL has attempt but no eval for a probe' do
      let(:interrupted_jsonl) do
        [
          { entry_type: 'init', start_time: '2024-01-01T00:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: 'test.ProbeA', uuid: 'a1', prompt: 'test', outputs: [ 'out' ] }.to_json
        ].join("\n")
      end

      before do
        create(:raw_report_data, report: report, jsonl_data: interrupted_jsonl)
      end

      it 'does not consider the probe as completed' do
        service = described_class.new(report)
        remaining = service.send(:remaining_probes)
        expect(remaining).to contain_exactly('test.ProbeA', 'test.ProbeB')
      end
    end
  end

  describe 'immediate process death handling' do
    let(:target) { create(:target, :good, model_type: 'OpenAIGenerator', model: 'gpt-4') }
    let(:scan) { create(:complete_scan, company: target.company) }
    let(:report) { create(:report, target: target, scan: scan, company: target.company) }

    before do
      allow(FileUtils).to receive(:mkdir_p)
      allow(File).to receive(:write)
      allow(Dir).to receive(:exist?).and_return(true)
      allow_any_instance_of(RunGarakScan).to receive(:call).and_call_original
    end

    it 'marks report as failed when process exits immediately' do
      service = described_class.new(report)

      run_command = instance_double(RunCommand)
      allow(RunCommand).to receive(:new).and_return(run_command)
      allow(run_command).to receive(:call_async).and_raise(
        RunCommand::ImmediateExitError.new(1, "/opt/venv/bin/python3 script/run_garak.py")
      )
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:error)

      service.call

      report.reload
      expect(report.status).to eq("failed")
      expect(report.logs).to include("Scan process failed to start (exit status 1)")
    end

    it 'includes log tail in failure message when log file exists' do
      service = described_class.new(report)

      run_command = instance_double(RunCommand)
      allow(RunCommand).to receive(:new).and_return(run_command)
      allow(run_command).to receive(:call_async).and_raise(
        RunCommand::ImmediateExitError.new(127, "/opt/venv/bin/python3 script/run_garak.py")
      )
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:error)

      log_path = LogPathManager.scan_log_file_for_report(report)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(log_path.to_s).and_return(true)
      allow(File).to receive(:read).with(log_path.to_s).and_return("python3: command not found\n")

      service.call

      report.reload
      expect(report.status).to eq("failed")
      expect(report.logs).to include("Output: python3: command not found")
    end
  end
end
