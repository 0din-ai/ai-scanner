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
end
