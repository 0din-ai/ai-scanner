require "rails_helper"

RSpec.describe Reports::ProviderErrorRecord do
  # Captured from a real run; see spec/fixtures/provider_errors/README.md.
  let(:identity_block_log) { Rails.root.join("spec/fixtures/provider_errors/openrouter_identity_block.log").read }

  def record_line(overrides = {})
    payload = {
      "v" => 1, "provider" => "OpenRouter", "model" => "openai/gpt-4o", "category" => "provider_error",
      "http_status" => 200, "provider_status" => nil, "provider_code" => nil, "provider_error_type" => nil,
      "request_id" => nil, "message" => nil
    }.merge(overrides)
    "2026-10-01 21:12:20,304 - root - ERROR - PROVIDER_ERROR #{payload.to_json}\n"
  end

  describe ".last_in" do
    it "reads the identity block the generator logged for a blocked OpenRouter route" do
      record = described_class.last_in(identity_block_log)

      expect(record.category).to eq("identity_policy_block")
      expect(record.failure_code).to eq("provider_policy_block")
      expect(record.provider).to eq("OpenRouter")
      expect(record.provider_status).to eq(403)
      expect(record.provider_error_type).to eq("refusal")
    end

    it "returns nil when the log carries no record" do
      expect(described_class.last_in("Garak scan completed - Report: x, Exit code: 0")).to be_nil
    end

    it "ignores malformed JSON and records of an unknown version" do
      log = "PROVIDER_ERROR {not json\n" + record_line("v" => 2)

      expect(described_class.last_in(log)).to be_nil
    end

    it "takes the last record in the current run" do
      log = record_line("category" => "auth_failed") + record_line("category" => "billing")

      expect(described_class.last_in(log).category).to eq("billing")
    end

    it "does not carry a record over from an earlier retry of the same report" do
      log = "2026-10-01 10:00:00,000 - __main__ - INFO - Starting garak scan - Report: r1, Scan: 1\n" +
        record_line("category" => "identity_policy_block") +
        "2026-10-01 11:00:00,000 - __main__ - INFO - Starting garak scan - Report: r1, Scan: 1\n" \
        "Garak scan completed - Report: r1, Exit code: 0\n"

      expect(described_class.last_in(log)).to be_nil
    end

    it "skips retried transient records when asked for a terminal one" do
      log = record_line("category" => "auth_failed") + record_line("category" => "upstream_unavailable")

      expect(described_class.last_in(log).category).to eq("upstream_unavailable")
      expect(described_class.last_in(log, terminal_only: true).category).to eq("auth_failed")
    end

    it "maps an unknown category to the generic provider_error code" do
      expect(described_class.last_in(record_line("category" => "brand_new")).failure_code).to eq("provider_error")
    end
  end

  describe "#explains_failure?" do
    # backoff's on_backoff handler logs this format on every retry it schedules,
    # including ones the next attempt recovers from.
    let(:backoff_line) do
      "2026-10-01 10:00:01,000 - backoff - INFO - Backing off _call_model(...) for 0.8s " \
        "(openai.InternalServerError: OpenRouter retryable provider envelope)\n"
    end
    let(:transient) { record_line("category" => "upstream_unavailable", "provider_status" => 502) }

    it "is always true for a terminal record" do
      log = record_line("category" => "auth_failed") + "Traceback (most recent call last):\nKeyError: 'x'\n"

      expect(described_class.last_in(log).explains_failure?).to be(true)
    end

    it "is true when garak gave up retrying the transient envelope" do
      log = transient + backoff_line + "Traceback (most recent call last):\n" \
        "openai.InternalServerError: OpenRouter retryable provider envelope\n"

      expect(described_class.last_in(log).explains_failure?).to be(true)
    end

    it "is true when the generator gave up retrying with ProviderRetryExhausted" do
      log = transient + "Traceback (most recent call last):\n" \
        "garak.generators.openrouter.ProviderRetryExhausted: PROVIDER_RETRY_EXHAUSTED category=upstream_unavailable\n"

      expect(described_class.last_in(log).explains_failure?).to be(true)
    end

    it "sees ProviderRetryExhausted as the final exception even after an earlier, recovered one" do
      log = transient + "Traceback (most recent call last):\nKeyError: 'x'\n" \
        "Traceback (most recent call last):\n" \
        "garak.generators.openrouter.ProviderRetryExhausted: PROVIDER_RETRY_EXHAUSTED category=upstream_unavailable\n"

      expect(described_class.last_in(log).explains_failure?).to be(true)
    end

    it "is false when a different exception follows ProviderRetryExhausted" do
      log = transient + "garak.generators.openrouter.ProviderRetryExhausted: PROVIDER_RETRY_EXHAUSTED category=rate_limited\n" \
        "Traceback (most recent call last):\nKeyError: 'description'\n"

      expect(described_class.last_in(log).explains_failure?).to be(false)
    end

    it "is true when nothing was raised after the transient record" do
      expect(described_class.last_in(transient + backoff_line).explains_failure?).to be(true)
    end

    it "is false when the retry recovered and a different exception ended the run" do
      log = transient + backoff_line + "Traceback (most recent call last):\n  File \"x.py\", line 1\n" \
        "KeyError: 'description'\n"

      expect(described_class.last_in(log).explains_failure?).to be(false)
    end

    it "is false when garak's own exception is the last one raised" do
      log = transient + backoff_line + "garak.exception.BadGeneratorException: route produced only None outputs\n"

      expect(described_class.last_in(log).explains_failure?).to be(false)
    end
  end

  describe "field allowlisting" do
    it "drops values that are not of the declared shape" do
      record = described_class.last_in(record_line(
        "model" => "not a slug", "provider_status" => "403", "http_status" => 999,
        "provider_code" => "bad code!", "request_id" => "sk-or-v1-abcdef"
      ))

      expect(record.model).to be_nil
      expect(record.provider_status).to be_nil
      expect(record.http_status).to be_nil
      expect(record.provider_code).to be_nil
      expect(record.request_id).to be_nil
    end

    it "redacts a JSON-quoted key the upstream message echoes" do
      record = described_class.last_in(record_line("message" => 'bad request {"api_key": "abc123secretvalue"}'))

      expect(record.message).not_to include("abc123secretvalue")
    end

    it "decodes a hex-encoded message and still redacts it" do
      hex = 'blocked {"api_key": "abc123secretvalue"}'.unpack1("H*")
      record = described_class.last_in(record_line("message_hex" => hex))

      expect(record.message).to start_with("blocked")
      expect(record.message).not_to include("abc123secretvalue")
    end

    it "survives RunCommand's output sanitizer when the message carries credentials and a cookie" do
      hex = 'bad key api_key="abc" Cookie: session=1'.unpack1("H*")
      captured = RunCommand.new([]).send(:sanitize_output,
        record_line("category" => "auth_failed", "http_status" => 401, "message_hex" => hex), truncate: false)

      record = described_class.last_in(captured)
      expect(record.category).to eq("auth_failed")
      expect(record.message).to start_with("bad key")
    end

    it "redacts secrets and truncates the upstream message" do
      record = described_class.last_in(record_line("message" => "bad key sk-or-v1-#{'a' * 40} " + ("x" * 400)))

      expect(record.message).not_to include("sk-or-v1")
      expect(record.message.length).to be <= described_class::MESSAGE_LIMIT
    end
  end

  describe "#user_message" do
    it "names the provider and model and never the upstream message" do
      record = described_class.last_in(identity_block_log)

      expect(record.user_message).to include("OpenRouter", "blocked this account for a previous policy violation")
      expect(record.user_message).to include(record.model, "Other models on the same key may still work")
      expect(record.user_message).not_to include("Learn more")
    end

    it "appends a request id that passed the allowlist" do
      record = described_class.last_in(record_line("request_id" => "gen-123-abc"))

      expect(record.user_message).to end_with("Request ID: gen-123-abc.")
    end
  end

  describe "#details" do
    it "keeps the redacted upstream message for operators" do
      details = described_class.last_in(identity_block_log).details

      expect(details).to include("provider" => "OpenRouter", "status_code" => 200, "provider_status" => 403,
        "provider_category" => "identity_policy_block", "provider_error_type" => "refusal")
      expect(details["provider_message"]).to include("blocked for a previous policy violation")
    end
  end
end
