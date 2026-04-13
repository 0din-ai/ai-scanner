require "rails_helper"

RSpec.describe BrowserAutomation::PlaywrightService do
  let(:service) { described_class.instance }

  before do
    service.instance_variable_set(:@browser_process, nil)
    service.instance_variable_set(:@browser_ready, false)
  end

  describe "#initialize" do
    it "is a Singleton" do
      expect(described_class).to include(Singleton)
    end

    it "has nil browser_process initially" do
      expect(service.browser_process).to be_nil
    end

    it "has browser_ready false initially" do
      expect(service.browser_ready).to be false
    end
  end

  describe "#screenshot" do
    let(:url) { "https://example.com" }
    let(:output_path) { "/tmp/screenshot.png" }
    let(:success_response) { { "success" => true, "path" => output_path }.to_json }

    before do
      allow(Open3).to receive(:capture3).and_return([ success_response, "", double(success?: true) ])
    end

    it "returns the output path on success" do
      result = service.screenshot(url, output_path)
      expect(result).to eq(output_path)
    end

    it "generates a screenshot path if not provided" do
      allow(service).to receive(:generate_screenshot_path).and_return("/tmp/generated.png")
      allow(Open3).to receive(:capture3).and_return([
        { "success" => true, "path" => "/tmp/generated.png" }.to_json,
        "",
        double(success?: true)
      ])

      result = service.screenshot(url)
      expect(result).to eq("/tmp/generated.png")
    end

    it "executes playwright script with correct parameters" do
      expect(Open3).to receive(:capture3).with(
        hash_including("NODE_PATH" => Rails.root.join("node_modules").to_s, "PLAYWRIGHT_DATA_PATH" => anything),
        "node",
        anything
      ).and_return([ success_response, "", double(success?: true) ])

      service.screenshot(url, output_path)
    end

    it "raises error on failure" do
      allow(Open3).to receive(:capture3).and_return([
        { "error" => "Browser crashed" }.to_json,
        "",
        double(success?: true)
      ])

      expect {
        service.screenshot(url, output_path)
      }.to raise_error("Screenshot failed: Browser crashed")
    end

    it "accepts custom options" do
      options = { width: 1024, height: 768, full_page: true }
      script_content = nil

      allow(Open3).to receive(:capture3) do |_env, _command, script_path|
        script_content = File.read(script_path)
        [ success_response, "", double(success?: true) ]
      end

      service.screenshot(url, output_path, options)

      expect(script_content).to include("width: 1024")
      expect(script_content).to include("height: 768")
      expect(script_content).to include("fullPage: true")
    end

    it "passes URL via JSON data file instead of interpolating into script" do
      script_content = nil
      data_content = nil

      allow(Open3).to receive(:capture3) do |env, _command, script_path|
        script_content = File.read(script_path)
        data_content = JSON.parse(File.read(env["PLAYWRIGHT_DATA_PATH"]))
        [ success_response, "", double(success?: true) ]
      end

      service.screenshot(url, output_path)

      expect(script_content).to include("__data.url")
      expect(script_content).not_to include("'https://example.com'")
      expect(data_content["url"]).to eq("https://example.com")
    end

    it "coerces numeric options to integers" do
      options = { width: "1024", height: "768", timeout: "5000" }
      script_content = nil

      allow(Open3).to receive(:capture3) do |_env, _command, script_path|
        script_content = File.read(script_path)
        [ success_response, "", double(success?: true) ]
      end

      service.screenshot(url, output_path, options)

      expect(script_content).to include("width: 1024")
      expect(script_content).to include("height: 768")
      expect(script_content).to include("timeout: 5000")
    end

    it "coerces full_page to strict boolean" do
      script_content = nil

      allow(Open3).to receive(:capture3) do |_env, _command, script_path|
        script_content = File.read(script_path)
        [ success_response, "", double(success?: true) ]
      end

      service.screenshot(url, output_path, { full_page: "yes" })
      expect(script_content).to include("fullPage: false")
    end
  end

  describe "#generate_pdf" do
    let(:url) { "https://example.com/report" }
    let(:output_path) { "/tmp/report.pdf" }
    let(:success_response) { { "success" => true, "path" => output_path }.to_json }

    before do
      allow(Open3).to receive(:capture3).and_return([ success_response, "", double(success?: true) ])
    end

    it "passes URL via JSON data file instead of interpolating into script" do
      script_content = nil
      data_content = nil

      allow(Open3).to receive(:capture3) do |env, _command, script_path|
        script_content = File.read(script_path)
        data_content = JSON.parse(File.read(env["PLAYWRIGHT_DATA_PATH"]))
        [ success_response, "", double(success?: true) ]
      end

      service.generate_pdf(url, output_path)

      expect(script_content).to include("__data.url")
      expect(script_content).not_to include("'https://example.com/report'")
      expect(data_content["url"]).to eq("https://example.com/report")
    end

    it "coerces boolean PDF options strictly" do
      script_content = nil

      allow(Open3).to receive(:capture3) do |_env, _command, script_path|
        script_content = File.read(script_path)
        [ success_response, "", double(success?: true) ]
      end

      service.generate_pdf(url, output_path, { print_background: "yes", prefer_css_page_size: 1 })

      expect(script_content).to include("printBackground: false")
      expect(script_content).to include("preferCSSPageSize: false")
    end

    it "defaults boolean PDF options to true" do
      script_content = nil

      allow(Open3).to receive(:capture3) do |_env, _command, script_path|
        script_content = File.read(script_path)
        [ success_response, "", double(success?: true) ]
      end

      service.generate_pdf(url, output_path)

      expect(script_content).to include("printBackground: true")
      expect(script_content).to include("preferCSSPageSize: true")
    end
  end

  describe "#validate_webchat_config" do
    let(:url) { "https://example.com/chat" }
    let(:config) do
      {
        selectors: {
          input_field: "#chat-input",
          send_button: "#send-btn",
          response_container: ".chat-messages"
        }
      }
    end

    context "when validation succeeds" do
      let(:success_response) do
        {
          "success" => true,
          "errors" => [],
          "response_detected" => true,
          "test_message_found" => true,
          "baseline_length" => 100,
          "new_length" => 150
        }.to_json
      end

      before do
        allow(Open3).to receive(:capture3).and_return([ success_response, "", double(success?: true) ])
      end

      it "returns success result" do
        result = service.validate_webchat_config(url, config)

        expect(result[:success]).to be true
        expect(result[:response_detected]).to be true
        expect(result[:errors]).to eq([])
      end

      it "includes response metrics" do
        result = service.validate_webchat_config(url, config)

        expect(result[:test_message_found]).to be true
        expect(result[:baseline_length]).to eq(100)
        expect(result[:new_length]).to eq(150)
      end
    end

    context "when validation fails" do
      let(:failure_response) do
        {
          "success" => false,
          "errors" => [ "Input field not found: #chat-input" ],
          "response_detected" => false
        }.to_json
      end

      before do
        allow(Open3).to receive(:capture3).and_return([ failure_response, "", double(success?: true) ])
      end

      it "returns failure result with errors" do
        result = service.validate_webchat_config(url, config)

        expect(result[:success]).to be false
        expect(result[:errors]).to include("Input field not found: #chat-input")
        expect(result[:response_detected]).to be false
      end
    end

    context "when script execution fails" do
      before do
        allow(Open3).to receive(:capture3).and_return([ "", "Node.js error", double(success?: false) ])
        allow(Rails.logger).to receive(:error)
      end

      it "returns error result" do
        result = service.validate_webchat_config(url, config)

        expect(result[:success]).to be false
        expect(result[:errors]).to be_an(Array)
        expect(result[:errors].first).to match(/Node.js error|Unknown validation error/)
      end
    end

    it "accepts config as hash with string keys" do
      string_config = {
        "selectors" => {
          "input_field" => "#input",
          "response_container" => "#response"
        }
      }

      allow(Open3).to receive(:capture3).and_return([
        { "success" => true, "errors" => [], "response_detected" => true }.to_json,
        "",
        double(success?: true)
      ])

      result = service.validate_webchat_config(url, string_config)
      expect(result[:success]).to be true
    end

    it "includes custom wait times if provided" do
      config_with_wait = config.merge(
        wait_times: {
          page_load: 60000,
          response: 10000
        }
      )

      script_content = nil
      allow(Open3).to receive(:capture3) do |_env, _command, script_path|
        script_content = File.read(script_path)
        [
          { "success" => true, "errors" => [], "response_detected" => true }.to_json,
          "",
          double(success?: true)
        ]
      end

      service.validate_webchat_config(url, config_with_wait)

      expect(script_content).to include("timeout: 60000")
      expect(script_content).to include("waitForTimeout(10000)")
    end

    it "passes selectors via JSON data file instead of interpolating into script" do
      script_content = nil
      data_content = nil

      allow(Open3).to receive(:capture3) do |env, _command, script_path|
        script_content = File.read(script_path)
        data_content = JSON.parse(File.read(env["PLAYWRIGHT_DATA_PATH"]))
        [
          { "success" => true, "errors" => [], "response_detected" => true }.to_json,
          "",
          double(success?: true)
        ]
      end

      service.validate_webchat_config(url, config)

      expect(script_content).to include("__data.input_selector")
      expect(script_content).to include("__data.container_selector")
      expect(script_content).not_to include("'#chat-input'")
      expect(script_content).not_to include("'.chat-messages'")
      expect(data_content["input_selector"]).to eq("#chat-input")
      expect(data_content["container_selector"]).to eq(".chat-messages")
      expect(data_content["send_selector"]).to eq("#send-btn")
    end
  end

  describe "#extract_page_structure" do
    let(:url) { "https://example.com/chat" }
    let(:page_data) do
      {
        "html" => {
          "elements" => {
            "inputs" => [ { "selector" => "#input", "type" => "text" } ],
            "buttons" => [ { "selector" => "#button", "text" => "Send" } ],
            "containers" => [ { "selector" => ".container", "height" => 500 } ]
          },
          "title" => "Example Chat",
          "url" => url
        },
        "metadata" => {
          "title" => "Example Chat",
          "url" => url
        },
        "screenshot" => "base64_encoded_image_data"
      }
    end

    let(:success_response) do
      {
        "success" => true,
        "data" => page_data
      }.to_json
    end

    before do
      allow(Open3).to receive(:capture3).and_return([ success_response, "", double(success?: true) ])
    end

    it "returns page data on success" do
      result = service.extract_page_structure(url)

      expect(result).to eq(page_data)
      expect(result["html"]["elements"]["inputs"]).to be_an(Array)
      expect(result["screenshot"]).to eq("base64_encoded_image_data")
    end

    it "raises error when extraction fails" do
      allow(Open3).to receive(:capture3).and_return([
        { "error" => "Page load timeout" }.to_json,
        "",
        double(success?: true)
      ])

      expect {
        service.extract_page_structure(url)
      }.to raise_error("Page structure extraction failed: Page load timeout")
    end

    it "raises error on unexpected result format" do
      allow(Open3).to receive(:capture3).and_return([
        { "unexpected" => "format" }.to_json,
        "",
        double(success?: true)
      ])

      expect {
        service.extract_page_structure(url)
      }.to raise_error(/Unexpected result format/)
    end

    it "accepts custom options" do
      options = { width: 1024, height: 768, timeout: 20000 }
      script_content = nil

      allow(Open3).to receive(:capture3) do |_env, _command, script_path|
        script_content = File.read(script_path)
        [ success_response, "", double(success?: true) ]
      end

      service.extract_page_structure(url, options)

      expect(script_content).to include("width: 1024")
      expect(script_content).to include("height: 768")
      expect(script_content).to include("timeout: 20000")
    end

    it "passes URL and user agent via JSON data file" do
      script_content = nil
      data_content = nil

      allow(Open3).to receive(:capture3) do |env, _command, script_path|
        script_content = File.read(script_path)
        data_content = JSON.parse(File.read(env["PLAYWRIGHT_DATA_PATH"]))
        [ success_response, "", double(success?: true) ]
      end

      service.extract_page_structure(url, { user_agent: "CustomAgent/1.0" })

      expect(script_content).to include("__data.url")
      expect(script_content).to include("__data.user_agent")
      expect(script_content).not_to include("'https://example.com/chat'")
      expect(data_content["url"]).to eq("https://example.com/chat")
      expect(data_content["user_agent"]).to eq("CustomAgent/1.0")
    end
  end

  describe "#stop_browser" do
    it "does nothing when no browser process exists" do
      expect { service.stop_browser }.not_to raise_error
    end

    it "kills browser process if it exists" do
      pid = 12345
      service.instance_variable_set(:@browser_process, pid)

      allow(Process).to receive(:kill)
      allow(Process).to receive(:wait)

      service.stop_browser

      expect(Process).to have_received(:kill).with("TERM", pid)
      expect(Process).to have_received(:wait).with(pid)
    end

    it "handles process kill errors gracefully and logs warning" do
      pid = 12345
      service.instance_variable_set(:@browser_process, pid)

      allow(Process).to receive(:kill).and_raise(Errno::ESRCH)
      allow(Process).to receive(:wait).and_raise(Errno::ECHILD)
      allow(Rails.logger).to receive(:warn)

      expect { service.stop_browser }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/failed to kill process/).once
      expect(Rails.logger).to have_received(:warn).with(/failed to wait on process/).once
    end

    it "logs warning when temp script unlink fails" do
      temp_script = instance_double(Tempfile)
      allow(temp_script).to receive(:unlink).and_raise(Errno::ENOENT.new("no such file"))
      service.instance_variable_set(:@temp_script, temp_script)
      allow(Rails.logger).to receive(:warn)

      service.stop_browser

      expect(Rails.logger).to have_received(:warn).with(/failed to unlink temp script/)
      expect(service.instance_variable_get(:@temp_script)).to be_nil
    end

    it "resets browser_ready flag" do
      pid = 12345
      service.instance_variable_set(:@browser_process, pid)
      service.instance_variable_set(:@browser_ready, true)

      allow(Process).to receive(:kill)
      allow(Process).to receive(:wait)

      service.stop_browser

      expect(service.browser_ready).to be false
    end
  end

  describe "private methods" do
    describe "#execute_playwright_script" do
      it "creates temporary script file" do
        script = "console.log('test');"
        allow(Open3).to receive(:capture3).and_return([
          { "success" => true }.to_json,
          "",
          double(success?: true)
        ])

        service.send(:execute_playwright_script, script)

        expect(Open3).to have_received(:capture3) do |env, command, script_path|
          expect(env["NODE_PATH"]).to eq(Rails.root.join("node_modules").to_s)
          expect(command).to eq("node")
          expect(File.exist?(script_path)).to be false
        end
      end

      it "parses JSON output correctly" do
        script = "console.log('test');"
        json_output = { "success" => true, "data" => "result" }.to_json

        allow(Open3).to receive(:capture3).and_return([ json_output, "", double(success?: true) ])

        result = service.send(:execute_playwright_script, script)

        expect(result).to eq({ "success" => true, "data" => "result" })
      end

      it "handles non-JSON output" do
        script = "console.log('test');"
        allow(Open3).to receive(:capture3).and_return([ "Not JSON output", "", double(success?: true) ])
        allow(Rails.logger).to receive(:error)

        result = service.send(:execute_playwright_script, script)

        expect(result["error"]).to include("No JSON found in output")
      end

      it "handles JSON parse errors" do
        script = "console.log('test');"
        allow(Open3).to receive(:capture3).and_return([ "{invalid json}", "", double(success?: true) ])
        allow(Rails.logger).to receive(:error)

        result = service.send(:execute_playwright_script, script)

        expect(result["error"]).to include("No JSON found in output")
      end

      it "cleans up temporary file even on error" do
        script = "console.log('test');"
        temp_file = instance_double(Tempfile)
        allow(Tempfile).to receive(:new).and_return(temp_file)
        allow(temp_file).to receive(:write)
        allow(temp_file).to receive(:close)
        allow(temp_file).to receive(:path).and_return("/tmp/test.js")
        allow(temp_file).to receive(:unlink)

        allow(Open3).to receive(:capture3).and_raise(StandardError)

        expect { service.send(:execute_playwright_script, script) }.to raise_error(StandardError)
        expect(temp_file).to have_received(:unlink)
      end

      it "writes data to a JSON temp file when data is provided" do
        script = "console.log('test');"
        test_data = { url: "https://example.com", selector: "#input" }

        allow(Open3).to receive(:capture3) do |env, _command, _script_path|
          data_path = env["PLAYWRIGHT_DATA_PATH"]
          expect(data_path).to be_present
          parsed = JSON.parse(File.read(data_path))
          expect(parsed["url"]).to eq("https://example.com")
          expect(parsed["selector"]).to eq("#input")
          [ { "success" => true }.to_json, "", double(success?: true) ]
        end

        service.send(:execute_playwright_script, script, data: test_data)
      end

      it "cleans up data file even on error" do
        script = "console.log('test');"
        test_data = { url: "https://example.com" }
        temp_paths = []

        allow(Tempfile).to receive(:new).and_wrap_original do |original, *args|
          file = original.call(*args)
          temp_paths << file.path
          file
        end

        allow(Open3).to receive(:capture3).and_raise(StandardError)

        expect { service.send(:execute_playwright_script, script, data: test_data) }.to raise_error(StandardError)

        expect(temp_paths.length).to eq(2)
        temp_paths.each do |path|
          expect(File.exist?(path)).to be false
        end
      end
    end

    describe "#generate_screenshot_path" do
      it "generates path with timestamp" do
        allow(Time).to receive(:current).and_return(Time.new(2025, 1, 15, 12, 30, 45))
        allow(FileUtils).to receive(:mkdir_p)

        path = service.send(:generate_screenshot_path)

        expect(path.to_s).to include("20250115_123045")
        expect(path.to_s).to include("storage/screenshots")
        expect(path.to_s).to end_with(".png")
      end

      it "creates screenshots directory if needed" do
        expect(FileUtils).to receive(:mkdir_p)

        service.send(:generate_screenshot_path)
      end
    end

    describe "#build_page_script" do
      it "includes conditional URL navigation using data" do
        script, data = service.send(:build_page_script, "https://example.com", {})

        expect(script).to include("if (__data.url)")
        expect(script).to include("__data.url")
        expect(script).not_to include("'https://example.com'")
        expect(data[:url]).to eq("https://example.com")
      end

      it "sets url to nil in data when URL is nil" do
        script, data = service.send(:build_page_script, nil, {})

        expect(script).to include("if (__data.url)")
        expect(data[:url]).to be_nil
      end

      it "does not include firefoxUserPrefs in chromium launch config" do
        script, _data = service.send(:build_page_script, "https://example.com", {})

        expect(script).not_to include("firefoxUserPrefs")
      end

      it "respects headless option" do
        script, _data = service.send(:build_page_script, "https://example.com", { headless: false })

        expect(script).to include("headless: false")
      end

      it "uses custom viewport dimensions" do
        script, _data = service.send(:build_page_script, "https://example.com", { width: 800, height: 600 })

        expect(script).to include("width: 800")
        expect(script).to include("height: 600")
      end

      it "passes wait_until via data hash" do
        _script, data = service.send(:build_page_script, "https://example.com", { wait_until: "load" })

        expect(data[:wait_until]).to eq("load")
      end
    end
  end

  describe "thread safety" do
    it "uses mutex for script execution" do
      mutex = service.instance_variable_get(:@mutex)
      expect(mutex).to be_a(Mutex)

      allow(Open3).to receive(:capture3).and_return([
        { "success" => true }.to_json,
        "",
        double(success?: true)
      ])

      expect(mutex).to receive(:synchronize).and_call_original

      service.send(:execute_playwright_script, "test script")
    end
  end

  describe "script injection prevention" do
    before do
      allow(service).to receive(:validate_url_safety!)
    end

    it "prevents URL injection in screenshot" do
      malicious_url = "https://example.com'); process.exit(1); //"
      script_content = nil
      data_content = nil

      allow(Open3).to receive(:capture3) do |env, _command, script_path|
        script_content = File.read(script_path)
        data_content = JSON.parse(File.read(env["PLAYWRIGHT_DATA_PATH"]))
        [ { "success" => true, "path" => "/tmp/test.png" }.to_json, "", double(success?: true) ]
      end

      service.screenshot(malicious_url, "/tmp/test.png")

      expect(script_content).not_to include("process.exit(1)")
      expect(script_content).not_to include(malicious_url)
      expect(data_content["url"]).to eq(malicious_url)
    end

    it "prevents URL injection in generate_pdf" do
      malicious_url = "https://example.com'); require('child_process').exec('id'); //"
      script_content = nil
      data_content = nil

      allow(Open3).to receive(:capture3) do |env, _command, script_path|
        script_content = File.read(script_path)
        data_content = JSON.parse(File.read(env["PLAYWRIGHT_DATA_PATH"]))
        [ { "success" => true, "path" => "/tmp/test.pdf" }.to_json, "", double(success?: true) ]
      end

      service.generate_pdf(malicious_url, "/tmp/test.pdf")

      expect(script_content).not_to include("child_process")
      expect(script_content).not_to include(malicious_url)
      expect(data_content["url"]).to eq(malicious_url)
    end

    it "prevents selector injection in validate_webchat_config" do
      malicious_selector = "'); process.exit(1); //"
      config = {
        selectors: {
          input_field: malicious_selector,
          send_button: "#send",
          response_container: "'); require('fs').writeFileSync('/tmp/pwned',''); //"
        }
      }

      script_content = nil
      data_content = nil

      allow(Open3).to receive(:capture3) do |env, _command, script_path|
        script_content = File.read(script_path)
        data_content = JSON.parse(File.read(env["PLAYWRIGHT_DATA_PATH"]))
        [
          { "success" => true, "errors" => [], "response_detected" => true }.to_json,
          "",
          double(success?: true)
        ]
      end

      service.validate_webchat_config("https://example.com", config)

      expect(script_content).not_to include("process.exit(1)")
      expect(script_content).not_to include("writeFileSync")
      expect(data_content["input_selector"]).to eq(malicious_selector)
      expect(data_content["container_selector"]).to eq(config[:selectors][:response_container])
    end

    it "prevents user agent injection in extract_page_structure" do
      malicious_agent = "Mozilla'); process.exit(1); //"
      script_content = nil

      allow(Open3).to receive(:capture3) do |_env, _command, script_path|
        script_content = File.read(script_path)
        [
          { "success" => true, "data" => { "html" => {}, "metadata" => {}, "screenshot" => "" } }.to_json,
          "",
          double(success?: true)
        ]
      end

      service.extract_page_structure("https://example.com", { user_agent: malicious_agent })

      expect(script_content).not_to include("process.exit(1)")
      expect(script_content).not_to include(malicious_agent)
    end

    it "prevents URL injection in build_page_script" do
      malicious_url = "https://example.com'); process.exit(1); //"
      script, data = service.send(:build_page_script, malicious_url, {})

      expect(script).not_to include("process.exit(1)")
      expect(script).not_to include(malicious_url)
      expect(data[:url]).to eq(malicious_url)
    end

    it "handles selectors containing quotes safely" do
      config = {
        selectors: {
          input_field: "input[name='message']",
          send_button: "button[aria-label=\"send\"]",
          response_container: ".chat-container"
        }
      }

      script_content = nil
      data_content = nil

      allow(Open3).to receive(:capture3) do |env, _command, script_path|
        script_content = File.read(script_path)
        data_content = JSON.parse(File.read(env["PLAYWRIGHT_DATA_PATH"]))
        [
          { "success" => true, "errors" => [], "response_detected" => true }.to_json,
          "",
          double(success?: true)
        ]
      end

      service.validate_webchat_config("https://example.com", config)

      expect(script_content).not_to include("input[name='message']")
      expect(data_content["input_selector"]).to eq("input[name='message']")
    end

    it "no untrusted string values appear in generated scripts" do
      test_url = "https://example.com/unique-marker-page"
      test_selector = "#unique-marker-selector"
      test_agent = "UniqueMarkerAgent/1.0"

      script_contents = []
      all_pass = true

      capture_script = lambda do |env, _command, script_path|
        script_contents << File.read(script_path)
        [ { "success" => true, "path" => "/tmp/x", "errors" => [], "response_detected" => true,
            "data" => { "html" => {}, "metadata" => {}, "screenshot" => "" } }.to_json, "", double(success?: true) ]
      end

      allow(Open3).to receive(:capture3, &capture_script)

      service.screenshot(test_url, "/tmp/test.png")
      service.generate_pdf(test_url, "/tmp/test.pdf")
      service.validate_webchat_config(test_url, {
        selectors: { input_field: test_selector, response_container: test_selector }
      })
      service.extract_page_structure(test_url, { user_agent: test_agent })

      script_contents.each do |content|
        all_pass &&= !content.include?(test_url)
      end
      expect(all_pass).to be true

      expect(script_contents[2]).not_to include(test_selector)
      expect(script_contents[3]).not_to include(test_agent)

      script_contents.each do |content|
        expect(content).not_to include("unique-marker-page")
      end
    end
  end

  describe "SSRF protection" do
    let(:blocked_urls) { %w[http://169.254.169.254 http://10.0.0.1 http://192.168.1.1 http://172.16.0.1] }

    it "blocks private/internal URLs in screenshot" do
      blocked_urls.each do |url|
        expect { service.screenshot(url) }.to raise_error(ArgumentError, /SSRF protection/), "Expected #{url} to be blocked"
      end
    end

    it "blocks private/internal URLs in generate_pdf" do
      blocked_urls.each do |url|
        expect { service.generate_pdf(url) }.to raise_error(ArgumentError, /SSRF protection/), "Expected #{url} to be blocked"
      end
    end

    it "blocks private/internal URLs in validate_webchat_config" do
      config = { selectors: { input_field: "#input", response_container: "#response" } }
      blocked_urls.each do |url|
        expect { service.validate_webchat_config(url, config) }.to raise_error(ArgumentError, /SSRF protection/), "Expected #{url} to be blocked"
      end
    end

    it "blocks private/internal URLs in extract_page_structure" do
      blocked_urls.each do |url|
        expect { service.extract_page_structure(url) }.to raise_error(ArgumentError, /SSRF protection/), "Expected #{url} to be blocked"
      end
    end

    it "blocks private/internal URLs in with_page" do
      blocked_urls.each do |url|
        expect { service.with_page(url) }.to raise_error(ArgumentError, /SSRF protection/), "Expected #{url} to be blocked"
      end
    end

    it "allows external URLs" do
      allow(Open3).to receive(:capture3).and_return([
        { "success" => true, "path" => "/tmp/test.png" }.to_json, "", double(success?: true)
      ])
      expect { service.screenshot("https://example.com", "/tmp/test.png") }.not_to raise_error
    end

    it "allows localhost in dev/test mode" do
      allow(Open3).to receive(:capture3).and_return([
        { "success" => true, "path" => "/tmp/test.png" }.to_json, "", double(success?: true)
      ])
      expect { service.screenshot("http://127.0.0.1:3000", "/tmp/test.png") }.not_to raise_error
    end

    it "raises ArgumentError with SSRF message on blocked URLs" do
      expect { service.screenshot("http://10.0.0.1") }.to raise_error(ArgumentError, /SSRF protection.*blocked internal address/)
    end
  end
end
