require 'rails_helper'

RSpec.describe Reports::FailureClassifier do
  subject(:result) { described_class.new(report, logs: logs, exit_code: exit_code, exception_message: exception_message).call }

  let(:target) { create(:target, model_type: 'OpenRouterGenerator', model: 'openai/gpt-4o') }
  let(:scan) { create(:complete_scan) }
  let(:report) { create(:report, target: target, scan: scan) }
  let(:logs) { nil }
  let(:exit_code) { nil }
  let(:exception_message) { nil }

  it 'returns an empty result when there is no evidence' do
    expect(result).not_to be_failed
    expect(result.details).to eq({})
  end

  it 'classifies explicit OpenRouter model unavailable errors' do
    logs = 'OpenRouter terminal API status error: status_code=404 message="No endpoints found for openai/gpt-4o"'
    result = described_class.new(report, logs: logs).call

    expect(result.code).to eq('provider_model_unavailable')
    expect(result.message).to include('OpenRouter')
    expect(result.details).to include(
      'provider' => 'OpenRouter',
      'model' => 'openai/gpt-4o',
      'status_code' => 404
    )
  end

  it 'classifies explicit OpenRouter billing errors' do
    logs = 'OpenRouter terminal API status error: status_code=402 message="credits exhausted"'

    expect(described_class.new(report, logs: logs).call.code).to eq('provider_payment_required')
  end

  it 'classifies explicit provider 5xx errors as temporary provider outages' do
    logs = 'OpenRouter terminal API status error: status_code=503 message="upstream unavailable"'

    expect(described_class.new(report, logs: logs).call.code).to eq('provider_service_unavailable')
  end

  it 'does not classify bare status-like text from normal model output' do
    logs = 'Model output: HTTP/1.1 401 Unauthorized. status=401. Request rejected examples.'

    expect(described_class.new(report, logs: logs).call).not_to be_failed
  end

  it 'does not classify transient provider HTTP errors after a successful garak run' do
    logs = <<~LOG
      2026-05-27 19:52:28,598 - root - INFO - probe init: <garak.probes.0din.AcademicCredentials object>
      2026-05-27 19:52:28,766 - httpx - INFO - HTTP Request: POST https://openrouter.ai/api/v1/chat/completions "HTTP/1.1 200 OK"
      2026-05-27 19:59:00,930 - httpx - INFO - HTTP Request: POST https://openrouter.ai/api/v1/chat/completions "HTTP/1.1 429 Too Many Requests"
      2026-05-27 23:13:53,174 - __main__ - INFO - Garak scan completed - Report: example-report, Exit code: 0
    LOG

    result = described_class.new(report, logs: logs).call

    expect(result.code).to be_nil
    expect(result.message).to be_nil
    expect(result.details).to eq({})
  end

  it 'uses provider error HTTP status evidence after earlier successful requests' do
    logs = <<~LOG
      HTTP Request: POST https://openrouter.ai/api/v1/chat/completions "HTTP/1.1 200 OK"
      HTTP Request: POST https://openrouter.ai/api/v1/chat/completions "HTTP/1.1 429 Too Many Requests"
    LOG

    result = described_class.new(report, logs: logs).call

    expect(result.code).to eq('provider_rate_limited')
    expect(result.details['status_code']).to eq(429)
  end

  it 'redacts credentials from messages and details' do
    logs = 'OpenRouter terminal API status error: status_code=401 message="invalid api key sk-or-v1-secretvalue" body={"authorization":"Bearer abc123","api_key":"plainsecret"}'

    result = described_class.new(report, logs: logs).call

    expect(result.code).to eq('provider_auth_failed')
    expect(result.message).not_to include('sk-or-v1-secretvalue')
    expect(result.details.to_s).not_to include('abc123')
    expect(result.details.to_s).not_to include('plainsecret')
  end

  it 'classifies target validation failures' do
    logs = 'Target validation failed: no responses received from target'

    expect(described_class.new(report, logs: logs).call.code).to eq('target_validation_failed')
  end

  it 'classifies garak runtime failures' do
    logs = 'Traceback (most recent call last): RuntimeError: garak failed'

    expect(described_class.new(report, logs: logs).call.code).to eq('garak_runtime_error')
  end

  it 'does not classify a post-completion digest error after a clean exit' do
    logs = <<~LOG
      2026-05-27 23:13:53,174 - __main__ - INFO - Garak scan completed - Report: example-report, Exit code: 0
      Traceback (most recent call last):
        File "report_digest.py", line 120, in _get_probe_info
      KeyError: 'description'
    LOG

    result = described_class.new(report, logs: logs).call

    expect(result).not_to be_failed
    expect(result.code).to be_nil
  end

  it 'classifies a runtime failure when the last exit code is non-zero despite an earlier clean exit' do
    logs = <<~LOG
      2026-05-27 22:00:00,000 - __main__ - INFO - Garak scan completed - Report: earlier-run, Exit code: 0
      2026-05-27 23:00:00,000 - root - INFO - probe init
      Traceback (most recent call last):
        File "garak/harnesses/base.py", line 80, in run
      RuntimeError: garak failed
      2026-05-27 23:13:53,174 - __main__ - INFO - Garak scan completed - Report: current-run, Exit code: 1
    LOG

    expect(described_class.new(report, logs: logs).call.code).to eq('garak_runtime_error')
  end

  it 'classifies a nonzero exit marker as a runtime failure even without a traceback' do
    logs = <<~LOG
      2026-05-27 23:10:00,000 - root - INFO - run complete, ending
      2026-05-27 23:13:53,174 - __main__ - INFO - Garak scan completed - Report: current-run, Exit code: 1
    LOG

    result = described_class.new(report, logs: logs).call
    expect(result.code).to eq('garak_runtime_error')
    expect(result.details['exit_code']).to eq(1)
  end

  describe "structured PROVIDER_ERROR records" do
    let(:target) { create(:target, model_type: "OpenRouterGenerator", model: "openai/gpt-4o") }

    context "with the identity block a blocked OpenRouter route logs" do
      let(:logs) { Rails.root.join("spec/fixtures/provider_errors/openrouter_identity_block.log").read }

      it "classifies a provider policy block from the record, not from prose" do
        expect(result.code).to eq("provider_policy_block")
        expect(result.message).to include("blocked this account for a previous policy violation")
        expect(result.details).to include("provider" => "OpenRouter", "status_code" => 200, "provider_status" => 403,
          "provider_category" => "identity_policy_block")
      end

      it "never reports the provider's error_type=refusal as a model result" do
        expect(result.code).not_to match(/refus|target_validation/)
      end
    end

    context "when the only record is a transient envelope the run never recovered from" do
      let(:logs) do
        <<~LOG
          2026-10-01 10:00:00,000 - __main__ - INFO - Starting garak scan - Report: r1, Scan: 1
          PROVIDER_ERROR {"category":"upstream_unavailable","http_status":200,"message":"Provider returned error","model":"openai/gpt-4o","provider":"OpenRouter","provider_code":null,"provider_error_type":null,"provider_status":502,"request_id":null,"v":1}
          2026-10-01 10:05:00,000 - __main__ - INFO - Garak scan completed - Report: r1, Exit code: 1
        LOG
      end

      it "names the outage instead of leaving the run unexplained" do
        expect(result.code).to eq("provider_service_unavailable")
        expect(result.details).to include("provider_status" => 502)
      end
    end

    context "when a transient envelope was retried and something else failed afterwards" do
      let(:logs) do
        <<~LOG
          2026-10-01 10:00:00,000 - __main__ - INFO - Starting garak scan - Report: r1, Scan: 1
          PROVIDER_ERROR {"category":"upstream_unavailable","http_status":200,"message":null,"model":"openai/gpt-4o","provider":"OpenRouter","provider_code":null,"provider_error_type":null,"provider_status":502,"request_id":null,"v":1}
          2026-10-01 10:00:01,000 - backoff - INFO - Backing off _call_model(...) for 0.8s (openai.InternalServerError: OpenRouter retryable provider envelope)
          Error running Garak scan: 'NoneType' object is not iterable
          Traceback (most recent call last):
          KeyError: 'description'
          2026-10-01 10:05:00,000 - __main__ - INFO - Garak scan completed - Report: r1, Exit code: 1
        LOG
      end

      it "reports the later runtime failure, not the recovered outage" do
        expect(result.code).to eq("garak_runtime_error")
      end
    end

    context "when garak gave up retrying the transient envelope" do
      let(:logs) do
        <<~LOG
          PROVIDER_ERROR {"category":"rate_limited","http_status":200,"message":null,"model":"openai/gpt-4o","provider":"OpenRouter","provider_code":null,"provider_error_type":null,"provider_status":429,"request_id":null,"v":1}
          Traceback (most recent call last):
          openai.RateLimitError: OpenRouter retryable provider envelope
          2026-10-01 10:05:00,000 - __main__ - INFO - Garak scan completed - Report: r1, Exit code: 1
        LOG
      end

      it "names the rate limit" do
        expect(result.code).to eq("provider_rate_limited")
      end
    end

    context "when retries saw an upstream 502 and finally gave up on a 429" do
      let(:logs) do
        <<~LOG
          2026-10-01 10:00:00,000 - __main__ - INFO - Starting garak scan - Report: r1, Scan: 1
          2026-10-01 10:00:01,000 - httpx - INFO - HTTP Request: POST https://openrouter.ai/api/v1/chat/completions "HTTP/1.1 502 Bad Gateway"
          PROVIDER_ERROR {"category":"rate_limited","http_status":429,"message_hex":null,"model":"openai/gpt-4o","provider":"OpenRouter","provider_code":null,"provider_error_type":null,"provider_status":null,"request_id":null,"v":1}
          Traceback (most recent call last):
          garak.generators.openrouter.ProviderRetryExhausted: PROVIDER_RETRY_EXHAUSTED category=rate_limited model=openai/gpt-4o
          2026-10-01 10:05:00,000 - __main__ - INFO - Garak scan completed - Report: r1, Exit code: 1
        LOG
      end

      it "reports the rate limit the retry loop gave up on, not the first HTTP status" do
        expect(result.code).to eq("provider_rate_limited")
        expect(result.details).to include("provider_category" => "rate_limited")
      end
    end

    context "when the record is from an earlier retry and the current run completed" do
      let(:logs) do
        <<~LOG
          2026-10-01 10:00:00,000 - __main__ - INFO - Starting garak scan - Report: r1, Scan: 1
          2026-10-01 10:00:01,000 - root - ERROR - PROVIDER_ERROR {"category":"auth_failed","http_status":401,"message":null,"model":null,"provider":"OpenRouter","provider_code":null,"provider_error_type":null,"provider_status":401,"request_id":null,"v":1}
          2026-10-01 11:00:00,000 - __main__ - INFO - Starting garak scan - Report: r1, Scan: 1
          2026-10-01 11:30:00,000 - __main__ - INFO - Garak scan completed - Report: r1, Exit code: 0
        LOG
      end

      it "ignores the stale record" do
        expect(result).not_to be_failed
      end
    end
  end

  describe ".sanitize_text" do
    it "redacts a Cookie header value" do
      expect(described_class.sanitize_text("Cookie: session=abc123; theme=dark")).not_to include("session=abc123")
    end
    it "fully redacts a Basic auth credential" do
      expect(described_class.sanitize_text("Authorization: Basic dXNlcjpwYXNzd29yZA==")).not_to include("dXNlcjpwYXNzd29yZA")
    end
    it "redacts a custom auth-ish header value" do
      expect(described_class.sanitize_text("X-Api-Token: super-secret-value")).not_to include("super-secret-value")
    end
    it "redacts JSON-quoted secret values" do
      sanitized = described_class.sanitize_text('{"api_key":"plainsecret","token": "abc123","password":"hunter2"}')
      expect(sanitized).not_to include("plainsecret")
      expect(sanitized).not_to include("abc123")
      expect(sanitized).not_to include("hunter2")
    end
  end
end
