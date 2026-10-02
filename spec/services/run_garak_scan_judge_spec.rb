# frozen_string_literal: true

require "rails_helper"

# The judge's configuration reaches garak ONLY through the process environment: the
# report's pinned snapshot as JUDGE_CONFIG and the deployment's key as JUDGE_API_KEY.
RSpec.describe RunGarakScan, "LLM judge environment" do
  let(:company) { create(:company) }
  let(:target) { ActsAsTenant.with_tenant(company) { create(:target, :good, company: company) } }
  let(:judge_on) do
    { "judge_enabled" => "true", "judge_provider" => "openrouter", "judge_model_name" => "openai/gpt-4.1-mini" }
  end

  subject(:service) { described_class.new(report) }

  before do
    SettingsService.clear_cache
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("JUDGE_API_KEY").and_return("sk-deploy-key")
  end

  def create_report
    ActsAsTenant.with_tenant(company) { create(:report, company: company, target: target) }
  end

  def build_env
    ActsAsTenant.with_tenant(company) { service.send(:build_env) }
  end

  def tenant_env(name, value)
    ActsAsTenant.with_tenant(company) do
      EnvironmentVariable.create!(env_name: name, env_value: value, company: company)
    end
  end

  context "when the report was created with the judge on" do
    before { SettingsService.set_judge_settings!(judge_on) }

    let(:report) { create_report }

    it "passes the report's pinned snapshot and the deployment key" do
      env = build_env

      expect(JSON.parse(env["JUDGE_CONFIG"])).to eq(report.judge_config)
      expect(env["JUDGE_API_KEY"]).to eq("sk-deploy-key")
    end

    it "uses the snapshot, not settings changed after the report was created" do
      report
      SettingsService.set_judge_settings!(judge_on.merge("judge_model_name" => "changed/model"))

      expect(JSON.parse(build_env["JUDGE_CONFIG"])["model"]).to eq("openai/gpt-4.1-mini")
    end

    it "overrides tenant environment variables named JUDGE_CONFIG and JUDGE_API_KEY" do
      tenant_env("JUDGE_CONFIG", '{"enabled":true,"provider":"openai","model":"tenant-model"}')
      tenant_env("JUDGE_API_KEY", "sk-tenant-key")

      env = build_env

      expect(JSON.parse(env["JUDGE_CONFIG"])["model"]).to eq("openai/gpt-4.1-mini")
      expect(env["JUDGE_API_KEY"]).to eq("sk-deploy-key")
    end

    it "never writes the configuration or the key into garak's config files or argv" do
      written = []
      allow(FileUtils).to receive(:mkdir_p)
      allow(Dir).to receive(:exist?).and_return(true)
      allow(File).to receive(:write) { |_path, content| written << content.to_s }

      argv = ActsAsTenant.with_tenant(company) { service.send(:build_argv) }

      everything = (written + argv).join("\n")
      expect(everything).not_to include("sk-deploy-key")
      expect(everything).not_to include("JUDGE")
      expect(everything).not_to include("band_low")
    end

    it "does not substitute the deployment key into a target config that names it" do
      substituted = ActsAsTenant.with_tenant(company) do
        service.send(:substitute_env_vars, '{"api_key": "$JUDGE_API_KEY"}', service.send(:merged_env_vars))
      end

      expect(substituted).not_to include("sk-deploy-key")
    end

    it "records that the launching worker had the key" do
      service.send(:record_judge_launch_status!)

      expect(report.reload.judge_stats).to eq("launch_status" => "ready")
    end

    it "records the launch status as part of launching the scan" do
      allow(service).to receive(:build_argv).and_return([ "python3", "script/run_garak.py", report.uuid ])
      captured_env = nil
      allow(RunCommand).to receive(:new) { |_argv, env:, **| captured_env = env; double(call_async: nil) }

      service.send(:execute_scan)

      expect(captured_env["JUDGE_API_KEY"]).to eq("sk-deploy-key")
      expect(report.reload.judge_stats["launch_status"]).to eq("ready")
    end

    it "records a missing key so the report does not look judged" do
      allow(ENV).to receive(:[]).with("JUDGE_API_KEY").and_return(nil)

      service.send(:record_judge_launch_status!)

      expect(report.reload.judge_stats).to eq("launch_status" => "key_missing")
    end
  end

  context "when the report was created with the judge off" do
    let(:report) { create_report }

    it "blanks both variables, even against tenant rows and a deployment key" do
      tenant_env("JUDGE_CONFIG", '{"enabled":true}')
      tenant_env("JUDGE_API_KEY", "sk-tenant-key")

      env = build_env

      expect(env).to include("JUDGE_CONFIG" => "", "JUDGE_API_KEY" => "")
    end

    it "stays off when the judge is enabled after the report was created" do
      report
      SettingsService.set_judge_settings!(judge_on)

      expect(build_env["JUDGE_CONFIG"]).to eq("")
    end

    it "records no launch status" do
      service.send(:record_judge_launch_status!)

      expect(report.reload.judge_stats).to eq({})
    end
  end
end

RSpec.describe ValidateTarget, "LLM judge environment" do
  it "never judges a validation run, whatever the tenant or deployment sets" do
    company = create(:company)
    target = ActsAsTenant.with_tenant(company) { create(:target, company: company) }
    ActsAsTenant.with_tenant(company) do
      EnvironmentVariable.create!(env_name: "JUDGE_CONFIG", env_value: '{"enabled":true}', company: company)
      env = described_class.new(target).send(:build_env)

      expect(env).to include("JUDGE_CONFIG" => "", "JUDGE_API_KEY" => "")
    end
  end
end
