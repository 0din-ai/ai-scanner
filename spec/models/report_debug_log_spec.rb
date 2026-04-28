require "rails_helper"

RSpec.describe ReportDebugLog, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:report) }
  end

  describe "validations" do
    subject { create(:report_debug_log) }

    it { is_expected.to validate_uniqueness_of(:report_id) }
  end

  describe "schema" do
    it "stores final logs and live tail fields" do
      expect(described_class.column_names).to include(
        "logs",
        "tail",
        "tail_offset",
        "tail_digest",
        "tail_synced_at",
        "tail_truncated"
      )
    end

    it "allows logs and tail to be blank" do
      debug_log = build(:report_debug_log, logs: nil, tail: nil)

      expect(debug_log).to be_valid
    end

    it "enforces one debug log row per report at the database layer" do
      index = ActiveRecord::Base.connection.indexes(:report_debug_logs).find do |candidate|
        candidate.columns == [ "report_id" ] && candidate.unique
      end

      expect(index).to be_present
    end
  end

  describe "report lifecycle" do
    it "is destroyed with its report" do
      report = create(:report)
      debug_log = create(:report_debug_log, report: report, logs: "stored logs")

      expect { report.destroy }.to change(described_class, :count).by(-1)
      expect(described_class.exists?(debug_log.id)).to be(false)
    end
  end

  describe ".clear_tail_for_report" do
    it "clears live tail fields without erasing final logs" do
      debug_log = create(
        :report_debug_log,
        logs: "final logs",
        tail: "live tail\n",
        tail_offset: 128,
        tail_digest: "tail-digest",
        tail_synced_at: 1.minute.ago,
        tail_truncated: true
      )

      described_class.clear_tail_for_report(debug_log.report_id)

      debug_log.reload
      expect(debug_log.logs).to eq("final logs")
      expect(debug_log.tail).to be_nil
      expect(debug_log.tail_offset).to eq(0)
      expect(debug_log.tail_digest).to be_nil
      expect(debug_log.tail_synced_at).to be_nil
      expect(debug_log.tail_truncated).to be(false)
    end
  end
end
