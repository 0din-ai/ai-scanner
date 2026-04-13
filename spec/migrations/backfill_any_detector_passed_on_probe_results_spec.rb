require "rails_helper"
require Rails.root.join("db/migrate/20260412044226_backfill_any_detector_passed_on_probe_results")

RSpec.describe BackfillAnyDetectorPassedOnProbeResults do
  let(:migration) { described_class.new }

  describe "#up" do
    let(:report) { create(:report) }
    let(:probe) { create(:probe) }
    let(:detector) { create(:detector) }

    before do
      ProbeResult.reset_column_information
    end

    it "sets any_detector_passed=true for rows with passed > 0" do
      pr = create(:probe_result, report: report, probe: probe, detector: detector,
                  passed: 3, total: 10, any_detector_passed: false)

      migration.up

      expect(pr.reload.any_detector_passed).to be true
    end

    it "leaves any_detector_passed=false for rows with passed = 0" do
      pr = create(:probe_result, report: report, probe: probe, detector: detector,
                  passed: 0, total: 10, any_detector_passed: false)

      migration.up

      expect(pr.reload.any_detector_passed).to be false
    end

    it "does not overwrite already-true any_detector_passed" do
      pr = create(:probe_result, report: report, probe: probe, detector: detector,
                  passed: 5, total: 10, any_detector_passed: true)

      migration.up

      expect(pr.reload.any_detector_passed).to be true
    end

    it "handles batches across many records" do
      results = 3.times.map do |i|
        p = create(:probe, name: "Probe#{i}")
        create(:probe_result, report: report, probe: p, detector: detector,
               passed: i, total: 10, any_detector_passed: false)
      end

      migration.up

      expect(results[0].reload.any_detector_passed).to be false
      expect(results[1].reload.any_detector_passed).to be true
      expect(results[2].reload.any_detector_passed).to be true
    end
  end
end
