# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Settings: LLM judge", type: :request do
  let(:company) { create(:company) }
  let(:super_admin) { create(:user, :super_admin, company: company) }

  let(:judge_params) do
    { judge_enabled: "true", judge_provider: "openrouter", judge_model_name: "openai/gpt-4.1-mini",
      judge_band_below: "0.15", judge_band_above: "0.25", judge_max_calls_per_scan: "500",
      judge_max_provider_errors: "5", judge_timeout_seconds: "30", judge_concurrency: "4" }
  end

  before do
    SettingsService.clear_cache
    super_admin.update!(current_company: company)
    sign_in super_admin
    ActsAsTenant.current_tenant = company
  end

  it "saves the judge unit and renders it back on the form" do
    patch settings_path, params: judge_params

    expect(response).to redirect_to(settings_path)
    expect(JudgeSettings.current).to include("judge_enabled" => true, "judge_provider" => "openrouter",
                                             "judge_model_name" => "openai/gpt-4.1-mini",
                                             "judge_band_below" => 0.15, "judge_max_calls_per_scan" => 500)

    get settings_path
    expect(response.body).to include("data-judge-settings")
    expect(response.body).to include('value="openai/gpt-4.1-mini"')
  end

  it "rejects an invalid unit with the failing key and writes none of the request's settings" do
    patch settings_path, params: judge_params.merge(judge_model_name: "", parallel_scans_limit: "7")

    expect(response).to redirect_to(settings_path)
    expect(flash[:alert]).to include("judge_model_name")
    expect(JudgeSettings.stored["judge_enabled"]).to eq("false")
    expect(SettingsService.parallel_scans_limit).not_to eq(7)
  end

  it "keeps stored judge values for fields a request does not carry" do
    SettingsService.set_judge_settings!(judge_params.transform_keys(&:to_s))

    patch settings_path, params: { judge_band_above: "0.05" }

    expect(JudgeSettings.current).to include("judge_enabled" => true, "judge_model_name" => "openai/gpt-4.1-mini",
                                             "judge_band_above" => 0.05)
  end

  it "leaves the judge alone when a request carries no judge field" do
    patch settings_path, params: { parallel_scans_limit: "6" }

    expect(Metadatum.where("key LIKE 'judge%'")).to be_empty
  end

  it "has no API key field and never renders the key from the environment" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("JUDGE_API_KEY").and_return("sk-never-render-me")

    get settings_path

    expect(response.body).not_to include("sk-never-render-me")
    expect(response.body).not_to match(/name="judge_api_key"/)
    expect(response.body).to include("set in the environment")
  end

  it "ignores an API key submitted with the form instead of storing it" do
    patch settings_path, params: judge_params.merge(judge_api_key: "sk-submitted")

    expect(Metadatum.where("value LIKE '%sk-submitted%'")).to be_empty
  end

  it "is not reachable by a non-super-admin" do
    member = create(:user, company: company)
    member.update!(current_company: company)
    sign_in member

    patch settings_path, params: judge_params

    expect(JudgeSettings.stored["judge_enabled"]).to eq("false")
  end
end
