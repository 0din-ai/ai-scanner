# frozen_string_literal: true

require "rails_helper"

RSpec.describe JudgeSettings do
  before { SettingsService.clear_cache }

  let(:enabled) do
    { "judge_enabled" => "true", "judge_provider" => "openai", "judge_model_name" => "gpt-4.1-mini",
      "judge_band_below" => "0.1", "judge_band_above" => "0.3" }
  end

  describe ".validate!" do
    it "types a valid unit and returns every key in declared order" do
      typed = described_class.validate!(enabled)

      expect(typed.keys).to eq(described_class::KEYS)
      expect(typed).to include("judge_enabled" => true, "judge_provider" => "openai",
                               "judge_band_below" => 0.1, "judge_band_above" => 0.3,
                               "judge_max_calls_per_scan" => 1000)
    end

    it "defaults to off" do
      expect(described_class.validate!({})["judge_enabled"]).to be(false)
    end

    it "rejects enabling without a model" do
      expect { described_class.validate!(enabled.merge("judge_model_name" => " ")) }
        .to raise_error(JudgeSettings::ValidationError, /\AModel is required/)
    end

    it "accepts only the fixed providers" do
      %w[openai_compatible custom http://evil].each do |provider|
        expect { described_class.validate!(enabled.merge("judge_provider" => provider)) }
          .to raise_error(JudgeSettings::ValidationError, /\AProvider /)
      end
    end

    it "rejects a boolean token it does not recognise rather than enabling the judge" do
      expect { described_class.validate!(enabled.merge("judge_enabled" => "yes please")) }
        .to raise_error(JudgeSettings::ValidationError, /\AEnable LLM judge /)
    end

    it "rejects a band width outside 0..1" do
      expect { described_class.validate!(enabled.merge("judge_band_below" => "1.5")) }
        .to raise_error(JudgeSettings::ValidationError, /\ABand below threshold /)
    end

    it "rejects integers outside the plugin's ranges" do
      expect { described_class.validate!(enabled.merge("judge_timeout_seconds" => "500")) }
        .to raise_error(JudgeSettings::ValidationError, /\ATimeout \(seconds\) /)
      expect { described_class.validate!(enabled.merge("judge_concurrency" => "2.5")) }
        .to raise_error(JudgeSettings::ValidationError, /\AConcurrent judge calls /)
    end

    it "requires the error circuit to open before the call budget runs out" do
      expect { described_class.validate!(enabled.merge("judge_max_calls_per_scan" => "10", "judge_max_provider_errors" => "10")) }
        .to raise_error(JudgeSettings::ValidationError, /\AProvider errors before stopping /)
      expect(described_class.validate!(enabled.merge("judge_max_calls_per_scan" => "1", "judge_max_provider_errors" => "1")))
        .to include("judge_max_calls_per_scan" => 1)
    end
  end

  describe "SettingsService.set_judge_settings!" do
    it "round-trips through the stored rows" do
      SettingsService.set_judge_settings!(enabled)

      expect(described_class.stored).to include("judge_enabled" => "true", "judge_model_name" => "gpt-4.1-mini")
      expect(described_class.current).to include("judge_enabled" => true, "judge_provider" => "openai",
                                                 "judge_band_above" => 0.3)
      expect(SettingsService.get("judge_provider")).to eq("openai")
    end

    it "writes nothing when the unit does not validate" do
      SettingsService.set_judge_settings!(enabled)

      expect { SettingsService.set_judge_settings!(enabled.merge("judge_model_name" => "other", "judge_concurrency" => "99")) }
        .to raise_error(JudgeSettings::ValidationError)
      expect(described_class.stored["judge_model_name"]).to eq("gpt-4.1-mini")
    end
  end

  describe ".current" do
    it "falls back to the defaults (judge off) when the stored rows no longer validate" do
      Metadatum.create!(key: "judge_enabled", value: "true")
      Metadatum.create!(key: "judge_provider", value: "removed_provider")

      expect(described_class.current["judge_enabled"]).to be(false)
    end
  end

  describe ".key_present?" do
    it "reads the deployment environment, not the database" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("JUDGE_API_KEY").and_return("sk-test")
      expect(described_class.key_present?).to be(true)

      allow(ENV).to receive(:[]).with("JUDGE_API_KEY").and_return(nil)
      expect(described_class.key_present?).to be(false)
    end
  end
end
