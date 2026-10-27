# frozen_string_literal: true

require "spec_helper"
require "yaml"

RSpec.describe "Docker release version metadata" do
  let(:root) { File.expand_path("../..", __dir__) }

  %w[build-amd64 build-arm64].each do |job|
    it "passes the semantic release version into #{job}" do
      workflow = YAML.safe_load_file(File.join(root, ".github/workflows/release.yml"))
      build = workflow.fetch("jobs").fetch(job).fetch("steps").find { |step| step["id"] == "build" }

      expect(build.fetch("with").fetch("build-args").lines.map(&:strip))
        .to include('APP_VERSION=${{ needs.release.outputs.version }}')
    end
  end

  %w[Dockerfile Dockerfile.dev].each do |filename|
    it "persists APP_VERSION in #{filename} after dependency layers" do
      lines = File.readlines(File.join(root, filename))
      argument = lines.index { |line| line.match?(/\AARG APP_VERSION=development\s*\z/) }
      environment = lines.index { |line| line.match?(/\AENV APP_VERSION=\$\{APP_VERSION\}\s*\z/) }

      expect(argument).not_to be_nil
      expect(environment).not_to be_nil
      expect(argument).to be > lines.rindex { |line| line.start_with?("FROM ") }
      expect(argument).to be > lines.rindex { |line| line.start_with?("RUN ") }
      expect(environment).to be > argument
      expect(lines.take(argument).join).not_to match(/\bAPP_VERSION\b/)
    end
  end
end
