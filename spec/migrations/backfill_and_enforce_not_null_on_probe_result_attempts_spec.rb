require "rails_helper"
require Rails.root.join("db/migrate/20260415120000_backfill_and_enforce_not_null_on_probe_result_attempts")

RSpec.describe BackfillAndEnforceNotNullOnProbeResultAttempts do
  let(:migration) { described_class.new }

  describe "#up" do
    let(:report) { create(:report) }
    let(:probe) { create(:probe) }
    let(:detector) { create(:detector) }

    before do
      migration.down
      ProbeResult.reset_column_information
    end

    after do
      migration.up
      ProbeResult.reset_column_information
    end

    it "backfills NULL attempts to empty array" do
      pr = create(:probe_result, report: report, probe: probe, detector: detector)
      pr.update_column(:attempts, nil)

      migration.up

      expect(pr.reload.attempts).to eq([])
    end

    it "preserves existing non-nil attempts" do
      data = [ { "prompt" => "hello", "response" => "world" } ]
      pr = create(:probe_result, report: report, probe: probe, detector: detector, attempts: data)

      migration.up

      expect(pr.reload.attempts).to eq(data)
    end

    it "enforces NOT NULL after migration" do
      migration.up

      expect {
        ActiveRecord::Base.transaction(requires_new: true) do
          ActiveRecord::Base.connection.execute(
            "INSERT INTO probe_results (report_id, probe_id, detector_id, attempts, created_at, updated_at) " \
            "VALUES (#{report.id}, #{probe.id}, #{detector.id}, NULL, NOW(), NOW())"
          )
        end
      }.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe "#down" do
    it "allows NULL attempts again" do
      migration.down

      expect {
        create(:probe_result).tap { |pr| pr.update_column(:attempts, nil) }
      }.not_to raise_error

      migration.up
    end
  end
end
