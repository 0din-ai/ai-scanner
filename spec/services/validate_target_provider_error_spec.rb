require "rails_helper"

# The generator logs one PROVIDER_ERROR record before raising. Validation must read it
# before cleanup deletes the log, on every path the run can end by.
RSpec.describe ValidateTarget, "provider error records", type: :service do
  let(:target) { create(:target, model_type: "OpenRouterGenerator", model: "openai/gpt-4o", tokens_per_second: 12.5) }
  let(:service) { described_class.new(target) }
  let(:validation_uuid) { "validation_#{target.id}_providererr" }
  let(:log_file) { described_class::LOGS_PATH.join("#{validation_uuid}.log") }
  let(:jsonl_file) { described_class::VALIDATION_REPORTS_PATH.join("#{validation_uuid}.report.jsonl") }
  # Captured from a real run; see spec/fixtures/provider_errors/README.md.
  let(:identity_block_log) { Rails.root.join("spec/fixtures/provider_errors/openrouter_identity_block.log").read }
  let(:run_command) { instance_double(RunCommand) }

  before do
    allow(service).to receive(:validation_uuid).and_return(validation_uuid)
    allow(RunCommand).to receive(:new).and_return(run_command)
    FileUtils.mkdir_p(described_class::LOGS_PATH)
    FileUtils.mkdir_p(described_class::VALIDATION_REPORTS_PATH)
  end

  after do
    [ log_file, jsonl_file ].each { |f| File.delete(f) if File.exist?(f) }
  end

  def write_jsonl(*rows)
    File.write(jsonl_file, rows.map(&:to_json).join("\n"))
  end

  context "when garak exits non-zero after a ProviderError" do
    before do
      allow(run_command).to receive(:call) do
        File.write(log_file, identity_block_log)
        raise "Command failed with error: Traceback ... PROVIDER_ERROR category=identity_policy_block"
      end
    end

    it "stores the mapped sentence and code instead of the command error" do
      service.call

      target.reload
      expect(target.status).to eq("bad")
      expect(target.validation_failure_code).to eq("provider_policy_block")
      expect(target.validation_text).to include("OpenRouter refused openai/gpt-4o")
      expect(target.validation_text).not_to include("Command failed")
      expect(target.tokens_per_second).to be_nil
    end

    it "removes the validation artifacts, including the credential-bearing config" do
      config_file = described_class::CONFIG_PATH.join("#{validation_uuid}.json")
      FileUtils.mkdir_p(described_class::CONFIG_PATH)
      File.write(config_file, "{}")

      service.call

      expect(File.exist?(log_file)).to be(false)
      expect(File.exist?(config_file)).to be(false)
    end
  end

  context "when garak swallowed the error and exited 0 with no output" do
    before do
      allow(run_command).to receive(:call) do
        File.write(log_file, identity_block_log)
        write_jsonl({ "entry_type" => "init" })
      end
    end

    it "reports the provider error instead of 'No responses received' and still cleans up" do
      service.call

      target.reload
      expect(target.validation_failure_code).to eq("provider_policy_block")
      expect(target.validation_text).not_to include("No responses received")
      expect(File.exist?(log_file)).to be(false)
    end
  end

  context "when the run left output and a valid eval row but also a provider error" do
    before do
      allow(run_command).to receive(:call) do
        File.write(log_file, identity_block_log)
        write_jsonl(
          { "entry_type" => "attempt", "outputs" => [ { "text" => "I cannot assist" } ] },
          { "entry_type" => "eval", "passed" => 1, "total_evaluated" => 1, "total_processed" => 1,
            "probe" => "0din.LitmusTest", "detector" => "0din.LitmusTest" }
        )
      end
    end

    it "does not validate the target" do
      service.call

      expect(target.reload.status).to eq("bad")
      expect(target.validation_failure_code).to eq("provider_policy_block")
    end
  end

  # Hand-built: the generator writes this record shape, then raises a retryable error
  # instead of ProviderError, and retries the call (script/garak_plugins/openrouter.py).
  let(:transient_line) do
    record = { "v" => 1, "provider" => "OpenRouter", "model" => "openai/gpt-4o", "category" => "upstream_unavailable",
               "http_status" => 200, "provider_status" => 502, "provider_code" => nil, "provider_error_type" => nil,
               "request_id" => nil, "message" => "Provider returned error" }
    "2026-10-01 21:12:20,304 - root - ERROR - PROVIDER_ERROR #{record.to_json}\n"
  end

  context "when a transient envelope was retried and the run then succeeded" do
    before do
      allow(run_command).to receive(:call) do
        File.write(log_file, transient_line)
        write_jsonl(
          { "entry_type" => "attempt", "outputs" => [ { "text" => "Hello there" } ] },
          { "entry_type" => "eval", "passed" => 1, "total_evaluated" => 1, "total_processed" => 1,
            "probe" => "0din.LitmusTest", "detector" => "0din.LitmusTest" }
        )
      end
    end

    it "validates the target" do
      service.call

      expect(target.reload.status).to eq("good")
      expect(target.validation_failure_code).to be_nil
    end
  end

  context "when a transient envelope never recovered and the run produced nothing" do
    before do
      allow(run_command).to receive(:call) do
        File.write(log_file, transient_line)
        write_jsonl({ "entry_type" => "init" })
      end
    end

    it "explains the failure with the transient record" do
      service.call

      expect(target.reload.status).to eq("bad")
      expect(target.validation_failure_code).to eq("provider_service_unavailable")
      expect(target.validation_text).not_to include("No responses received")
    end
  end

  context "when a transient envelope recovered and validation then failed for another reason" do
    before do
      allow(run_command).to receive(:call) do
        File.write(log_file, transient_line +
          "2026-10-01 21:12:21,000 - backoff - INFO - Backing off _call_model(...) for 0.8s " \
          "(openai.InternalServerError: OpenRouter retryable provider envelope)\n" \
          "Traceback (most recent call last):\nKeyError: 'description'\n")
        raise "Command failed with error: KeyError: 'description'"
      end
    end

    it "keeps the real error instead of blaming the recovered provider" do
      service.call

      expect(target.reload.validation_failure_code).to be_nil
      expect(target.validation_text).to include("KeyError")
    end
  end

  context "when the transient envelope ended the run before garak wrote a report" do
    before do
      allow(run_command).to receive(:call) { File.write(log_file, transient_line) }
    end

    it "names the outage instead of 'Validation report file not found'" do
      service.call

      expect(target.reload.validation_failure_code).to eq("provider_service_unavailable")
      expect(File.exist?(log_file)).to be(false)
    end
  end

  context "when a later validation succeeds" do
    before do
      target.update!(status: :bad, validation_failure_code: "provider_policy_block")
      allow(run_command).to receive(:call)
      allow(service).to receive(:process_validation_result) { target.update!(status: :good) }
    end

    it "clears the stale code" do
      service.call

      expect(target.reload.validation_failure_code).to be_nil
    end
  end
end
