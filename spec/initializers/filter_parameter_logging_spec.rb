# frozen_string_literal: true

require "rails_helper"

RSpec.describe "filter_parameter_logging" do
  let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  it "filters the LLM judge API key from logged parameters" do
    filtered = filter.filter("judge_api_key" => "sk-secret", "JUDGE_API_KEY" => "sk-secret",
                             "judge_model_name" => "gpt-4.1-mini")

    expect(filtered["judge_api_key"]).to eq("[FILTERED]")
    expect(filtered["JUDGE_API_KEY"]).to eq("[FILTERED]")
    expect(filtered["judge_model_name"]).to eq("gpt-4.1-mini")
  end
end
