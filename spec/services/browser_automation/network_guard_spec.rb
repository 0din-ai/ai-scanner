require "rails_helper"
require "open3"

# The guard is what keeps UrlSafetyValidator's blocklist in force for the browser's
# whole navigation lifetime. These specs cover the Ruby half: that the blocklist
# handed to the browser is UrlSafetyValidator's own, that every tenant-driven
# Playwright entry point installs the guard, and that a blocked request is surfaced
# rather than swallowed. The interception behaviour itself lives in the JS the guard
# emits and is covered by driving a real browser, not from here.
RSpec.describe BrowserAutomation::NetworkGuard do
  describe ".payload" do
    it "hands over UrlSafetyValidator's blocklist rather than a second copy" do
      expect(described_class.payload["blocked_cidrs"]).to eq(UrlSafetyValidator.blocked_cidrs)
    end

    it "covers the ranges an SSRF would aim at" do
      cidrs = described_class.payload["blocked_cidrs"]
      expect(cidrs).to include("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12",
                               "192.168.0.0/16", "169.254.0.0/16")
    end

    it "follows UrlSafetyValidator's localhost policy by default" do
      allow(UrlSafetyValidator).to receive(:allow_localhost?).and_return(false)
      expect(described_class.payload["allow_loopback"]).to be(false)

      allow(UrlSafetyValidator).to receive(:allow_localhost?).and_return(true)
      expect(described_class.payload["allow_loopback"]).to be(true)
    end

    it "coerces an explicit override to a strict boolean" do
      expect(described_class.payload(allow_localhost: "yes")["allow_loopback"]).to be(true)
      expect(described_class.payload(allow_localhost: false)["allow_loopback"]).to be(false)
    end
  end

  describe "GUARD_JS" do
    it "screens every request through the context, not just the page" do
      # context.route covers popups and every page in the context; page.route would
      # miss a window the target opens.
      expect(described_class::GUARD_JS).to include("context.route('**/*'")
    end

    it "walks the redirect chain itself" do
      # Chromium follows 3xx internally without re-invoking route handlers, so a
      # guard that only screens route.request().url() misses the redirect pivot -
      # which is the exact bug being fixed.
      expect(described_class::GUARD_JS).to include("maxRedirects: 0")
      expect(described_class::GUARD_JS).to include("redirect to ")
    end

    it "refuses to run without a blocklist instead of browsing unguarded" do
      expect(described_class::GUARD_JS).to include("refusing to browse unguarded")
    end
  end
end

RSpec.describe BrowserAutomation::PlaywrightService, "network guard wiring" do
  let(:service) { described_class.instance }
  let(:url) { "https://example.com" }

  # Capture the script and data file each entry point hands to node.
  def capture(result: { "success" => true })
    script = nil
    data = nil
    allow(Open3).to receive(:capture3) do |env, _cmd, script_path|
      script = File.read(script_path)
      data = JSON.parse(File.read(env["PLAYWRIGHT_DATA_PATH"]))
      [ result.to_json, "", double(success?: true) ]
    end
    yield
    [ script, data ]
  end

  # Every entry point that navigates to a TENANT-supplied URL must install the guard.
  {
    "screenshot" => ->(s) { s.screenshot("https://example.com", "/tmp/x.png") },
    "with_page" => ->(s) { s.with_page("https://example.com") },
    "extract_page_structure" => ->(s) { s.extract_page_structure("https://example.com") },
    "validate_webchat_config" => lambda do |s|
      s.validate_webchat_config(
        "https://example.com",
        { "selectors" => { "input_field" => "#i", "response_container" => "#r" } }
      )
    end
  }.each do |name, invoke|
    context "##{name}" do
      it "installs the network guard on the browser context" do
        script, data = capture(result: { "success" => true, "path" => "/tmp/x.png", "data" => {}, "errors" => [] }) do
          invoke.call(service)
        end

        expect(script).to include("__installNetworkGuard(context, __data.network_guard)")
        expect(data["network_guard"]["blocked_cidrs"]).to eq(UrlSafetyValidator.blocked_cidrs)
      end

      it "passes the blocklist through the data file, never interpolated into the script" do
        script, = capture(result: { "success" => true, "path" => "/tmp/x.png", "data" => {}, "errors" => [] }) do
          invoke.call(service)
        end

        # The blocklist arriving as script text would mean a value could reach the
        # script string; every other value in these scripts goes via the data file.
        expect(script).not_to include('"169.254.0.0/16"')
      end
    end
  end

  describe "#generate_pdf" do
    it "is deliberately left unguarded because it renders Scanner's own report URL" do
      script, data = capture(result: { "success" => true, "path" => "/tmp/x.pdf" }) do
        service.generate_pdf("http://localhost:3000/reports/1.pdf", "/tmp/x.pdf", allow_localhost: true)
      end

      # Guarding this would block Scanner from rendering its own pages whenever the
      # app is reachable only on a container address the blocklist covers.
      expect(script).not_to include("__installNetworkGuard")
      expect(data).not_to have_key("network_guard")
    end
  end

  describe "blocked request reporting" do
    it "warns with what the guard aborted so a silent block is not invisible" do
      allow(Rails.logger).to receive(:warn)
      result = {
        "success" => true,
        "path" => "/tmp/x.png",
        "blocked_requests" => [
          { "url" => "http://169.254.169.254/latest/meta-data/", "reason" => "redirect to blocked internal address" }
        ]
      }
      allow(Open3).to receive(:capture3).and_return([ result.to_json, "", double(success?: true) ])

      service.screenshot(url, "/tmp/x.png")

      expect(Rails.logger).to have_received(:warn)
        .with(/network guard blocked 1 request.*169\.254\.169\.254/)
    end

    it "stays quiet when nothing was blocked" do
      allow(Rails.logger).to receive(:warn)
      allow(Open3).to receive(:capture3).and_return([
        { "success" => true, "path" => "/tmp/x.png", "blocked_requests" => [] }.to_json,
        "", double(success?: true)
      ])

      service.screenshot(url, "/tmp/x.png")

      expect(Rails.logger).not_to have_received(:warn).with(/network guard/)
    end
  end
end
