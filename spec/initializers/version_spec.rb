# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Application version" do
  around do |example|
    original_version = Rails.application.config.version
    example.run
  ensure
    Rails.application.config.version = original_version
  end

  {
    "1.19.2" => "1.19.2",
    "1.20.0-rc.1" => "1.20.0-rc.1",
    "  1.19.2 \n" => "1.19.2",
    nil => "development",
    "" => "development",
    " \t\n" => "development"
  }.each do |supplied_version, expected_version|
    it "displays #{expected_version.inspect} for APP_VERSION=#{supplied_version.inspect}" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("APP_VERSION").and_return(supplied_version)

      load Rails.root.join("config/initializers/version.rb")

      expect(Rails.application.config.version).to eq(expected_version)
    end
  end
end
