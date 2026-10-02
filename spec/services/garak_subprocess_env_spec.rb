require "rails_helper"

RSpec.describe GarakSubprocessEnv do
  it "copies only allowlisted names from the source environment" do
    source = { "PATH" => "/bin", "HTTPS_PROXY" => "http://p", "SECRET_KEY_BASE" => "s3cr3t", "RAILS_MASTER_KEY" => "k" }

    expect(described_class.inherited(source)).to eq("PATH" => "/bin", "HTTPS_PROXY" => "http://p")
  end

  it "reserves every inherited name so key_env_var cannot read it" do
    expect(described_class::INHERITED_NAMES).to all(satisfy { |name| GarakEnvKeyGuard.reserved?(name) })
  end
end

RSpec.describe RunCommand, "isolated_env" do
  around do |example|
    previous = ENV.fetch("SECRET_KEY_BASE_FOR_ISOLATION_SPEC", nil)
    ENV["SECRET_KEY_BASE_FOR_ISOLATION_SPEC"] = "must-not-leak"
    example.run
  ensure
    previous.nil? ? ENV.delete("SECRET_KEY_BASE_FOR_ISOLATION_SPEC") : ENV["SECRET_KEY_BASE_FOR_ISOLATION_SPEC"] = previous
  end

  it "starts the child with only the given env" do
    output = described_class.new([ "/usr/bin/env" ], env: { "PATH" => ENV.fetch("PATH"), "ONLY_THIS" => "1" },
                                                       isolated_env: true).call

    expect(output).to include("ONLY_THIS=1")
    expect(output).not_to include("must-not-leak")
  end

  it "still inherits the worker env by default" do
    expect(described_class.new([ "/usr/bin/env" ]).call).to include("must-not-leak")
  end
end
