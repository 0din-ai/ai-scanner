require "rails_helper"

RSpec.describe Target, type: :model do
  describe "associations" do
    it { is_expected.to have_many(:reports).dependent(:destroy) }
    it { is_expected.to have_many(:environment_variables).dependent(:destroy) }
    it { is_expected.to have_and_belong_to_many(:scans) }
  end

  describe "validations" do
    subject { build(:target) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_uniqueness_of(:name).scoped_to(:company_id) }
    it { is_expected.to validate_presence_of(:model_type) }
    it { is_expected.to validate_presence_of(:model) }
  end

  describe "model format validation" do
    context "for API targets" do
      it "accepts valid model identifiers" do
        valid_models = [ "gpt-4", "gpt-3.5-turbo", "claude-2", "meta-llama/Llama-2-7b", "openai:gpt-4", "model_v2" ]
        valid_models.each do |model_name|
          target = build(:target, target_type: :api, model: model_name)
          target.valid?
          expect(target.errors[:model]).to be_empty, "Expected '#{model_name}' to be valid but got: #{target.errors[:model]}"
        end
      end

      it "rejects models with shell injection characters" do
        dangerous_models = [
          "'; rm -rf /; echo '",
          "gpt-4; whoami",
          "model$(id)",
          "model`id`",
          "model | cat /etc/passwd",
          "model && echo pwned",
          "model > /tmp/evil"
        ]
        dangerous_models.each do |model_name|
          target = build(:target, target_type: :api, model: model_name)
          expect(target).not_to be_valid, "Expected '#{model_name}' to be rejected"
          expect(target.errors[:model].first).to include("contains invalid characters")
        end
      end

      it "allows blank model (handled by presence validation)" do
        target = build(:target, target_type: :api, model: nil)
        target.valid?
        expect(target.errors[:model]).to include("can't be blank")
        expect(target.errors[:model]).not_to include(/contains invalid characters/)
      end
    end

    context "for webchat targets" do
      it "does not validate model format" do
        target = build(:target, target_type: :webchat, model: "WebChatbotGenerator",
                      web_config: {
                        "url" => "https://example.com/chat",
                        "selectors" => { "input_field" => "#input", "response_container" => "#response" }
                      })
        expect(target).to be_valid
      end
    end
  end

  describe "model_type validation" do
    context "for API targets" do
      it "accepts known generator types from INVERTED_MODEL_TYPES" do
        valid_types = [ "OpenAIGenerator", "AzureOpenAIGenerator", "LiteLLMGenerator", "OllamaGenerator" ]
        valid_types.each do |type|
          target = build(:target, target_type: :api, model_type: type)
          target.valid?
          expect(target.errors[:model_type]).to be_empty, "Expected '#{type}' to be valid but got: #{target.errors[:model_type]}"
        end
      end

      it "rejects unrecognized generator types" do
        target = build(:target, target_type: :api, model_type: "FakeGenerator")
        expect(target).not_to be_valid
        expect(target.errors[:model_type].first).to include("is not a recognized generator type")
      end

      it "rejects model_type with injection characters" do
        target = build(:target, target_type: :api, model_type: "openai; rm -rf /")
        expect(target).not_to be_valid
      end
    end

    context "for webchat targets" do
      it "does not validate model_type against the allowlist" do
        target = build(:target, target_type: :webchat, model_type: "web_chatbot",
                      web_config: {
                        "url" => "https://example.com/chat",
                        "selectors" => { "input_field" => "#input", "response_container" => "#response" }
                      })
        expect(target).to be_valid
      end
    end
  end

  describe "json_config validation" do
    context "for API targets" do
      it "accepts valid JSON when json_config is present" do
        target = build(:target, target_type: :api, json_config: '{"key": "value"}')
        expect(target).to be_valid
      end

      it "rejects invalid JSON when json_config is present" do
        target = build(:target, target_type: :api, json_config: "{key: value}")
        expect(target).not_to be_valid
        expect(target.errors[:json_config]).to include(/must be valid JSON/)
      end

      it "accepts blank json_config (validation skipped)" do
        target = build(:target, target_type: :api, json_config: nil)
        expect(target).to be_valid
      end

      it "accepts empty string json_config (validation skipped)" do
        target = build(:target, target_type: :api, json_config: "")
        expect(target).to be_valid
      end
    end

    context "for webchat targets" do
      it "does not validate json_config even if invalid" do
        # Webchat targets don't use json_config, so validation should be skipped
        target = build(:target, target_type: :webchat, json_config: "{invalid json}",
                      web_config: {
                        "url" => "https://example.com/chat",
                        "selectors" => {
                          "input_field" => "#input",
                          "response_container" => "#response"
                        }
                      })
        expect(target).to be_valid
      end

      it "allows blank json_config" do
        target = build(:target, target_type: :webchat, json_config: nil,
                      web_config: {
                        "url" => "https://example.com/chat",
                        "selectors" => {
                          "input_field" => "#input",
                          "response_container" => "#response"
                        }
                      })
        expect(target).to be_valid
      end
    end
  end

  describe "soft delete functionality" do
    let(:target) { create(:target) }

    describe "default scope" do
      it "excludes deleted records by default" do
        active_target = create(:target)
        deleted_target = create(:target, deleted_at: Time.current)

        expect(Target.all).to include(active_target)
        expect(Target.all).not_to include(deleted_target)
      end
    end

    describe "scopes" do
      let!(:active_target) { create(:target) }
      let!(:deleted_target) { create(:target, deleted_at: Time.current) }

      describe ".deleted" do
        it "returns only deleted records" do
          expect(Target.deleted).to include(deleted_target)
          expect(Target.deleted).not_to include(active_target)
        end
      end

      describe ".with_deleted" do
        it "returns all records including deleted" do
          expect(Target.with_deleted).to include(active_target)
          expect(Target.with_deleted).to include(deleted_target)
        end
      end
    end

    describe "#mark_deleted!" do
      it "sets deleted_at to current time" do
        freeze_time do
          expect { target.mark_deleted! }.to change { target.deleted_at }.from(nil).to(Time.current)
        end
      end

      it "persists the deletion timestamp" do
        target.mark_deleted!
        target.reload
        expect(target.deleted_at).to be_present
      end

      it "excludes the record from default scope after deletion" do
        target.mark_deleted!
        expect(Target.all).not_to include(target)
      end
    end

    describe "#deleted?" do
      it "returns false for active targets" do
        expect(target.deleted?).to be false
      end

      it "returns true for deleted targets" do
        target.mark_deleted!
        expect(target.deleted?).to be true
      end
    end

    describe "#restore!" do
      before { target.mark_deleted! }

      it "sets deleted_at to nil" do
        expect { target.restore! }.to change { target.deleted_at }.from(be_present).to(nil)
      end

      it "persists the restoration" do
        target.restore!
        target.reload
        expect(target.deleted_at).to be_nil
      end

      it "includes the record in default scope after restoration" do
        target.restore!
        expect(Target.all).to include(target)
      end
    end

    describe "associations with deleted targets" do
      let!(:scan) { create(:complete_scan) }
      let!(:report) { create(:report, target: target, scan: scan) }
      let!(:env_var) { create(:environment_variable, target: target) }

      it "preserves associated records when target is soft deleted" do
        target.mark_deleted!

        # Reports and environment variables should still exist
        expect(Report.find(report.id)).to be_present
        expect(EnvironmentVariable.find(env_var.id)).to be_present
      end

      it "allows access to associations through with_deleted scope" do
        target.mark_deleted!

        deleted_target = Target.with_deleted.find(target.id)
        expect(deleted_target.reports).to include(report)
        expect(deleted_target.environment_variables).to include(env_var)
      end
    end

    describe "ransackable_attributes" do
      it "includes deleted_at in searchable attributes" do
        expect(Target.ransackable_attributes).to include("deleted_at")
      end
    end
  end

  describe "status enum" do
    let(:target) { create(:target) }

    it "defines the correct status values" do
      expect(Target.statuses).to eq({
        "validating" => 0,
        "good" => 1,
        "bad" => 2
      })
    end

    it "defaults to validating status" do
      expect(target.status).to eq("validating")
      expect(target.validating?).to be true
    end

    it "can be set to good status" do
      target.update(status: :good)
      expect(target.good?).to be true
      expect(target.status).to eq("good")
    end

    it "can be set to bad status" do
      target.update(status: :bad)
      expect(target.bad?).to be true
      expect(target.status).to eq("bad")
    end

    it "includes status in ransackable attributes" do
      expect(Target.ransackable_attributes).to include("status")
    end
  end

  describe "#validate_target_on_config_change" do
    it "does not trigger duplicate validation on create" do
      expect {
        create(:target, json_config: '{"key": "value"}')
      }.to have_enqueued_job(ValidateTargetJob).once
    end

    it "triggers validation when json_config changes" do
      target = create(:target, :good, json_config: '{"key": "v1"}')

      expect {
        target.update!(json_config: '{"key": "v2"}')
      }.to have_enqueued_job(ValidateTargetJob)
    end

    it "triggers validation when web_config changes" do
      allow(UrlSafetyValidator).to receive(:resolve_addresses).and_return([ "93.184.216.34" ])
      target = create(:target, :good, target_type: :webchat,
                      web_config: {
                        "url" => "https://old.example.com/chat",
                        "selectors" => { "input_field" => "#input", "response_container" => "#response" }
                      })

      expect {
        target.update!(web_config: {
          "url" => "https://new.example.com/chat",
          "selectors" => { "input_field" => "#input", "response_container" => "#response" }
        })
      }.to have_enqueued_job(ValidateTargetJob)
    end

    it "does not trigger validation on unrelated attribute change" do
      target = create(:target, :good, json_config: '{"key": "v1"}')

      expect {
        target.update!(description: "new description")
      }.not_to have_enqueued_job(ValidateTargetJob)
    end
  end

  describe "validation methods" do
    let(:target) { create(:target) }

    describe "#validate_target!" do
      it "enqueues a ValidateTargetJob" do
        expect {
          target.validate_target!
        }.to have_enqueued_job(ValidateTargetJob).with(target.id)
      end
    end

    describe "#validate_target_now!" do
      let(:validate_service) { instance_double(ValidateTarget) }

      before do
        allow(ValidateTarget).to receive(:new).with(target).and_return(validate_service)
        allow(validate_service).to receive(:call)
      end

      it "creates and calls ValidateTarget service" do
        expect(ValidateTarget).to receive(:new).with(target).and_return(validate_service)
        expect(validate_service).to receive(:call)

        target.validate_target_now!
      end
    end
  end

  describe "target_type enum" do
    it "defines the correct target_type values" do
      expect(Target.target_types).to eq({
        "api" => 0,
        "webchat" => 1
      })
    end

    it "defaults to api type" do
      target = build(:target)
      expect(target.api?).to be true
    end

    it "can be set to webchat type" do
      target = build(:target, target_type: :webchat)
      expect(target.webchat?).to be true
      expect(target.api?).to be false
    end
  end

  describe "webchat functionality" do
    let(:valid_web_config) do
      {
        "url" => "https://example.com/chat",
        "selectors" => {
          "input_field" => "#chat-input",
          "send_button" => "button[type='submit']",
          "response_container" => ".chat-messages",
          "input" => "#chat-input",
          "response_area" => ".chat-messages"
        }
      }
    end

    describe "#web_chat_url" do
      it "returns the URL from web_config" do
        target = build(:target, target_type: :webchat, web_config: valid_web_config)
        expect(target.web_chat_url).to eq("https://example.com/chat")
      end

      it "returns nil when web_config is blank" do
        target = build(:target, target_type: :webchat, web_config: nil)
        expect(target.web_chat_url).to be_nil
      end

      it "returns nil when web_config has no URL" do
        target = build(:target, target_type: :webchat, web_config: { "selectors" => {} })
        expect(target.web_chat_url).to be_nil
      end

      it "works with JSON string web_config" do
        target = build(:target, target_type: :webchat, web_config: valid_web_config.to_json)
        expect(target.web_chat_url).to eq("https://example.com/chat")
      end
    end

    describe "#web_chat_selectors" do
      it "returns a hash of selectors" do
        target = build(:target, target_type: :webchat, web_config: valid_web_config)
        selectors = target.web_chat_selectors

        expect(selectors[:input]).to eq("#chat-input")
        expect(selectors[:send_button]).to eq("button[type='submit']")
        expect(selectors[:response_area]).to eq(".chat-messages")
      end

      it "returns empty hash when web_config is blank" do
        target = build(:target, target_type: :webchat, web_config: nil)
        expect(target.web_chat_selectors).to eq({})
      end

      it "returns empty hash when selectors are missing" do
        target = build(:target, target_type: :webchat, web_config: { "url" => "https://example.com" })
        expect(target.web_chat_selectors).to eq({})
      end

      it "works with JSON string web_config" do
        target = build(:target, target_type: :webchat, web_config: valid_web_config.to_json)
        selectors = target.web_chat_selectors

        expect(selectors[:input]).to eq("#chat-input")
        expect(selectors[:send_button]).to eq("button[type='submit']")
        expect(selectors[:response_area]).to eq(".chat-messages")
      end
    end

    describe "#parsed_web_config" do
      it "parses JSON string config" do
        target = build(:target, web_config: valid_web_config.to_json)
        parsed = target.parsed_web_config

        expect(parsed).to be_a(Hash)
        expect(parsed["url"]).to eq("https://example.com/chat")
      end

      it "returns hash config as-is" do
        target = build(:target, web_config: valid_web_config)
        expect(target.parsed_web_config).to eq(valid_web_config)
      end

      it "returns nil for blank config" do
        target = build(:target, web_config: nil)
        expect(target.parsed_web_config).to be_nil
      end

      it "returns nil for invalid JSON" do
        target = build(:target, web_config: "{invalid json}")
        expect(target.parsed_web_config).to be_nil
      end

      it "logs a warning for invalid JSON" do
        target = build(:target, web_config: "{invalid json}")
        expect(Rails.logger).to receive(:warn).with(/Target#parsed_web_config: invalid JSON/)
        target.parsed_web_config
      end
    end

    describe "#display_model_info" do
      it "displays webchat URL for webchat targets" do
        target = build(:target, target_type: :webchat, web_config: valid_web_config)
        expect(target.display_model_info).to eq("Web Chat: https://example.com/chat")
      end

      it "displays model type and name for API targets" do
        target = build(:target, target_type: :api, model_type: "text-generation", model: "gpt-4")
        expect(target.display_model_info).to eq("text-generation: gpt-4")
      end
    end

    describe "#set_defaults_for_webchat callback" do
      it "sets model_type to web_chatbot for new webchat targets" do
        target = build(:target, target_type: :webchat, model_type: nil, web_config: valid_web_config)
        target.valid? # Trigger validations which call before_validation callback

        expect(target.model_type).to eq("web_chatbot")
      end

      it "sets model to WebChatbotGenerator for new webchat targets" do
        target = build(:target, target_type: :webchat, model: nil, web_config: valid_web_config)
        target.valid?

        expect(target.model).to eq("WebChatbotGenerator")
      end

      it "does not override existing model_type" do
        target = build(:target, target_type: :webchat, model_type: "custom-type", web_config: valid_web_config)
        target.valid?

        expect(target.model_type).to eq("custom-type")
      end

      it "does not set defaults for API targets" do
        target = build(:target, target_type: :api, model_type: nil, model: nil)
        target.valid?

        expect(target.model_type).to be_nil
        expect(target.model).to be_nil
      end
    end
  end

  describe "web_config validation" do
    context "with valid config" do
      it "accepts config with URL and required selectors" do
        target = build(:target, target_type: :webchat, web_config: {
          "url" => "https://example.com/chat",
          "selectors" => {
            "input_field" => "#input",
            "response_container" => "#response"
          }
        })

        expect(target).to be_valid
      end

      it "accepts config with HTTPS URL" do
        allow(UrlSafetyValidator).to receive(:resolve_addresses).and_return([ "93.184.216.34" ])
        target = build(:target, target_type: :webchat, web_config: {
          "url" => "https://secure.example.com/chat",
          "selectors" => { "input_field" => "#input", "response_container" => "#response" }
        })

        expect(target).to be_valid
      end

      it "accepts config with HTTP URL" do
        target = build(:target, target_type: :webchat, web_config: {
          "url" => "http://example.com/chat",
          "selectors" => { "input_field" => "#input", "response_container" => "#response" }
        })

        expect(target).to be_valid
      end

      it "accepts config with optional send_button" do
        target = build(:target, target_type: :webchat, web_config: {
          "url" => "https://example.com/chat",
          "selectors" => {
            "input_field" => "#input",
            "send_button" => "#send",
            "response_container" => "#response"
          }
        })

        expect(target).to be_valid
      end
    end

    context "with invalid config" do
      it "rejects config without URL" do
        target = build(:target, target_type: :webchat, web_config: {
          "selectors" => {
            "input_field" => "#input",
            "response_container" => "#response"
          }
        })

        expect(target).not_to be_valid
        expect(target.errors[:web_config]).to include("must include a URL")
      end

      it "rejects config with blank URL" do
        target = build(:target, target_type: :webchat, web_config: {
          "url" => "",
          "selectors" => { "input_field" => "#input", "response_container" => "#response" }
        })

        expect(target).not_to be_valid
        expect(target.errors[:web_config]).to include("must include a URL")
      end

      it "rejects config with invalid URL" do
        target = build(:target, target_type: :webchat, web_config: {
          "url" => "not-a-valid-url",
          "selectors" => { "input_field" => "#input", "response_container" => "#response" }
        })

        expect(target).not_to be_valid
        expect(target.errors[:web_config]).to include("must include a valid URL")
      end

      it "rejects config without selectors object" do
        target = build(:target, target_type: :webchat, web_config: {
          "url" => "https://example.com/chat"
        })

        expect(target).not_to be_valid
        expect(target.errors[:web_config]).to include("must include a 'selectors' object with input_field and response_container")
      end

      it "rejects config with blank selectors" do
        target = build(:target, target_type: :webchat, web_config: {
          "url" => "https://example.com/chat",
          "selectors" => {}
        })

        expect(target).not_to be_valid
        expect(target.errors[:web_config]).to include(/input_field/)
        expect(target.errors[:web_config]).to include(/response_container/)
      end

      it "rejects config missing input_field selector" do
        target = build(:target, target_type: :webchat, web_config: {
          "url" => "https://example.com/chat",
          "selectors" => {
            "response_container" => "#response"
          }
        })

        expect(target).not_to be_valid
        expect(target.errors[:web_config]).to include(/input_field/)
      end

      it "rejects config missing response_container selector" do
        target = build(:target, target_type: :webchat, web_config: {
          "url" => "https://example.com/chat",
          "selectors" => {
            "input_field" => "#input"
          }
        })

        expect(target).not_to be_valid
        expect(target.errors[:web_config]).to include(/response_container/)
      end
    end

    context "with SSRF protection" do
      it "rejects URLs pointing to localhost" do
        target = build(:target, target_type: :webchat, web_config: {
          "url" => "http://127.0.0.1/chat",
          "selectors" => { "input_field" => "#input", "response_container" => "#response" }
        })
        allow(UrlSafetyValidator).to receive(:safe_url?).and_return(
          UrlSafetyValidator::Result.new("safe?": false, error: "blocked")
        )

        expect(target).not_to be_valid
        expect(target.errors[:web_config]).to include("must include a valid URL")
      end

      it "rejects URLs pointing to cloud metadata endpoint" do
        target = build(:target, target_type: :webchat, web_config: {
          "url" => "http://169.254.169.254/latest/meta-data",
          "selectors" => { "input_field" => "#input", "response_container" => "#response" }
        })
        allow(UrlSafetyValidator).to receive(:safe_url?).and_return(
          UrlSafetyValidator::Result.new("safe?": false, error: "blocked")
        )

        expect(target).not_to be_valid
      end

      it "rejects URLs pointing to private networks" do
        %w[http://10.0.0.1 http://172.16.0.1 http://192.168.1.1].each do |url|
          target = build(:target, target_type: :webchat, web_config: {
            "url" => url,
            "selectors" => { "input_field" => "#input", "response_container" => "#response" }
          })
          allow(UrlSafetyValidator).to receive(:safe_url?).and_return(
            UrlSafetyValidator::Result.new("safe?": false, error: "blocked")
          )

          expect(target).not_to be_valid, "Expected #{url} to be rejected"
        end
      end
    end

    context "with API targets" do
      it "skips web_config validation for API targets" do
        target = build(:target, target_type: :api, web_config: nil)
        expect(target).to be_valid
      end

      it "allows blank web_config for API targets" do
        target = build(:target, target_type: :api, web_config: "")
        expect(target).to be_valid
      end
    end
  end
end
