# frozen_string_literal: true

require "rails_helper"

RSpec.describe Report, "judge_config snapshot" do
  let(:company) { create(:company) }
  let(:target) { ActsAsTenant.with_tenant(company) { create(:target, company: company) } }
  let(:judge_on) do
    { "judge_enabled" => "true", "judge_provider" => "nim", "judge_model_name" => "meta/llama-3.1-70b-instruct",
      "judge_band_below" => "0.2", "judge_band_above" => "0.3", "judge_max_calls_per_scan" => "200",
      "judge_max_provider_errors" => "3", "judge_timeout_seconds" => "20", "judge_concurrency" => "2" }
  end

  before { SettingsService.clear_cache }

  def create_report(**attrs)
    ActsAsTenant.with_tenant(company) { create(:report, company: company, target: target, **attrs) }
  end

  it "is {} when the judge is off" do
    report = create_report

    expect(report.reload.judge_config).to eq({})
    expect(report.judge_enabled?).to be(false)
  end

  it "pins the exact JUDGE_CONFIG contract object, centred on the report's threshold" do
    SettingsService.set_judge_settings!(judge_on)

    report = create_report(evaluation_threshold: 0.5)

    expect(report.reload.judge_config).to eq(
      "enabled" => true, "provider" => "nim", "model" => "meta/llama-3.1-70b-instruct",
      "band_low" => 0.3, "band_high" => 0.8, "threshold" => 0.5,
      "prompt_version" => "v1", "max_calls" => 200, "max_provider_errors" => 3,
      "timeout_seconds" => 20, "concurrency" => 2
    )
    expect(report.judge_config.keys).to match_array(Reports::JudgeConfigSnapshot::CONTRACT_KEYS)
    expect(report.judge_enabled?).to be(true)
  end

  it "serialises integer fields as JSON integers and carries no custom-endpoint field" do
    SettingsService.set_judge_settings!(judge_on)

    json = create_report(evaluation_threshold: 0.5).judge_config.to_json

    expect(json).to include('"max_calls":200', '"max_provider_errors":3', '"timeout_seconds":20', '"concurrency":2')
    expect(json).not_to include("endpoint")
  end

  it "clamps the band to 0..1" do
    SettingsService.set_judge_settings!(judge_on.merge("judge_band_above" => "0.9"))

    report = create_report(evaluation_threshold: 0.5)

    expect(report.judge_config).to include("band_low" => 0.3, "band_high" => 1.0)
  end

  it "uses the threshold resolved for the report's target" do
    SettingsService.set_judge_settings!(judge_on)
    ActsAsTenant.with_tenant(company) do
      EnvironmentVariable.create!(env_name: "EVALUATION_THRESHOLD", env_value: "0.4", company: company)
    end

    report = create_report

    expect(report.judge_config["threshold"]).to eq(0.4)
  end

  it "is never rewritten by a later settings change" do
    SettingsService.set_judge_settings!(judge_on)
    report = create_report

    SettingsService.set_judge_settings!(judge_on.merge("judge_enabled" => "false"))
    report.update!(name: "renamed")

    expect(report.reload.judge_enabled?).to be(true)
  end

  it "makes a variant child inherit its parent's snapshot, including off" do
    parent = create_report
    SettingsService.set_judge_settings!(judge_on)

    child = create_report(parent_report: parent)

    expect(child.judge_config).to eq({})
  end

  it "makes a variant child inherit an enabled parent's snapshot" do
    SettingsService.set_judge_settings!(judge_on)
    parent = create_report
    SettingsService.set_judge_settings!(judge_on.merge("judge_model_name" => "other/model"))

    child = create_report(parent_report: parent)

    expect(child.judge_config).to eq(parent.judge_config)
  end
end
