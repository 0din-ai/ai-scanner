require "rails_helper"

RSpec.describe GarakEnvKeyGuard do
  let(:key_name) { "MY_API_KEY" }
  let(:rest_config) do
    { "rest" => { "RestGenerator" => { "uri" => "https://example.com/v1", "key_env_var" => key_name,
                                       "headers" => { "Authorization" => "Bearer $KEY" } } } }.to_json
  end

  describe ".referenced_names" do
    it "finds every *_env_var generator option in the shapes garak loads" do
      config = { "azure" => { "AzureOpenAIGenerator" => { "model_name_env_var" => "M", "endpoint_env_var" => "E" } },
                 "rest" => { "RestGenerator" => { "client_key_passphrase_env_var" => "P", "ENV_VAR" => "V" } },
                 "rest.RestGenerator" => { "KEY_ENV_VAR" => "K" } }.to_json

      expect(described_class.referenced_names(config)).to contain_exactly("M", "E", "P", "V", "K")
    end

    it "ignores literal request data that happens to use an env_var field name" do
      config = { "rest" => { "RestGenerator" => {
        "req_template_json_object" => { "env_var" => "staging", "meta" => { "key_env_var" => "x" } },
        "headers" => { "X-Env-Var" => "y" }
      } } }.to_json

      expect(described_class.referenced_names(config)).to eq([])
    end
  end

  describe ".violations" do
    it "allows a variable the tenant defined" do
      expect(described_class.violations(rest_config, { "MY_API_KEY" => "tenant-secret" })).to eq([])
    end

    it "rejects a variable the tenant did not define (an inherited deployment secret)" do
      expect(described_class.violations(rest_config, {})).to eq([ "MY_API_KEY" ])
    end

    %w[DATABASE_URL SCAN_EXECUTION_TOKEN JUDGE_API_KEY HOME DATABASE_QUEUE_URL HTTPS_PROXY].each do |reserved|
      it "rejects #{reserved} even when the tenant has a row with that name" do
        expect(described_class.violations(rest_config.sub("MY_API_KEY", reserved), { reserved => "x" })).to eq([ reserved ])
      end
    end
  end

  describe "launch-time check (RunGarakScan#env_key_violations)" do
    let(:target) do
      create(:target, :good, model_type: "RestGenerator", model: "RestGenerator",
        json_config: { "rest" => { "RestGenerator" => { "key_env_var" => "$KEY_NAME" } } }.to_json)
    end
    let(:report) do
      create(:report, target: target, company: target.company, scan: create(:complete_scan, company: target.company))
    end

    before do
      ActsAsTenant.with_tenant(target.company) do
        create(:environment_variable, company: target.company, env_name: "KEY_NAME", env_value: key_name)
        create(:environment_variable, company: target.company, env_name: "MY_API_KEY", env_value: "tenant-secret")
      end
    end

    it "accepts a placeholder that resolves to the tenant's own variable" do
      expect(RunGarakScan.new(report).send(:env_key_violations)).to eq([])
    end

    context "when the placeholder resolves to a deployment secret" do
      let(:key_name) { "DATABASE_URL" }

      it "rejects it" do
        expect(RunGarakScan.new(report).send(:env_key_violations)).to eq([ "DATABASE_URL" ])
      end
    end
  end

  # The guard is only sound while it knows every name the launchers set beyond the
  # tenant's rows. This fails as soon as a build_env starts assigning a new name.
  describe "RESERVED coverage" do
    let(:target) { create(:target, :good, model_type: "OpenAIGenerator", model: "gpt-4") }

    it "covers every name RunGarakScan#build_env sets beyond the tenant's rows" do
      report = create(:report, target: target, company: target.company,
        scan: create(:complete_scan, company: target.company))
      service = RunGarakScan.new(report)
      env = service.send(:build_env)
      tenant = ActsAsTenant.with_tenant(target.company) { service.send(:merged_env_vars) }

      expect((env.keys - tenant.keys).reject { |name| described_class.reserved?(name) }).to eq([])
    end

    it "covers every name ValidateTarget#build_env sets beyond the tenant's rows" do
      service = ValidateTarget.new(target)
      env = ActsAsTenant.with_tenant(target.company) { service.send(:build_env) }
      tenant = ActsAsTenant.with_tenant(target.company) { service.send(:merged_env_vars_hash) }

      expect((env.keys - tenant.keys).reject { |name| described_class.reserved?(name) }).to eq([])
    end
  end
end
