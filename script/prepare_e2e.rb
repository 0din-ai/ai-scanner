# Run explicitly against a development/test database with:
# E2E_FIXTURES=1 bin/rails runner script/prepare_e2e.rb
abort "E2E fixtures require development/test and E2E_FIXTURES=1" unless
  (Rails.env.development? || Rails.env.test?) && ENV["E2E_FIXTURES"] == "1"

# These upstream probes send only empty input and ordinary test strings. Keep
# browser integration tests independent of the changing production probe catalog.
require "open3"
metadata, status = Open3.capture2("python3", "-c", <<~PYTHON)
  import json
  from garak.probes.test import Blank, Test
  print(json.dumps({f"test.{probe.__name__}": {
      "detector": probe.primary_detector, "prompts": probe.prompts
  } for probe in (Blank, Test)}))
PYTHON
abort "Could not load garak's E2E probe metadata" unless status.success?

JSON.parse(metadata).each do |name, attributes|
  detector = Detector.with_deleted.find_or_initialize_by(name: attributes.fetch("detector"))
  detector.update!(deleted_at: nil)

  probe = Probe.find_or_initialize_by(name: name)
  probe.guid ||= SecureRandom.uuid
  probe.update!(category: "test", source: "garak", enabled: true,
    description: "Benign browser integration test fixture",
    detector: detector, prompts: attributes.fetch("prompts"))
end

puts "Prepared test.Blank and test.Test E2E fixtures"
