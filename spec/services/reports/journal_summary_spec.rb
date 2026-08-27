# frozen_string_literal: true

require "rails_helper"

# The single definition of "completed probe" while a scan is in flight. Resumption and
# the progress card both read it, so a disagreement here would tell a user a probe was
# done that the next attempt then re-ran, or the reverse.
RSpec.describe Reports::JournalSummary do
  let(:company) { create(:company) }
  let(:report) { ActsAsTenant.with_tenant(company) { create(:report, company: company) } }

  def journal(*lines)
    create(:raw_report_data, report: report, jsonl_data: lines.map(&:to_json).join("\n"), logs_data: nil)
  end

  def eval_row(probe:, detector: "detector.test", passed: 1, total: 4)
    { entry_type: "eval", probe: probe, detector: detector, passed: passed, total_evaluated: total }
  end

  describe "completed probes" do
    it "counts a probe once however many detectors evaluated it" do
      # garak emits one eval per DETECTOR. Counting rows would multiply a probe by its
      # detector count and report more work done than there is.
      journal(eval_row(probe: "0din.A", detector: "detector.one"),
              eval_row(probe: "0din.A", detector: "detector.two"))

      expect(described_class.for(report).completed_count).to eq(1)
    end

    it "ignores an eval row that evaluated nothing" do
      # A zero total is not completed work -- it is what the resume path retries.
      journal(eval_row(probe: "0din.A", total: 0))

      expect(described_class.for(report).completed_probes).to be_empty
    end

    it "ignores an eval row with no probe or detector" do
      journal({ entry_type: "eval", passed: 1, total_evaluated: 4 })

      expect(described_class.for(report).completed_probes).to be_empty
    end

    it "ignores impossible counts" do
      journal(eval_row(probe: "0din.A", passed: 9, total: 4))

      expect(described_class.for(report).completed_probes).to be_empty
    end

    it "reports the last completed probe in journal order" do
      journal(eval_row(probe: "0din.A"), eval_row(probe: "0din.B"))

      expect(described_class.for(report).last_completed_probe).to eq("0din.B")
    end
  end

  describe "start time" do
    it "takes the FIRST init, so a resumed run still reports the whole run's start" do
      journal({ entry_type: "init", start_time: "2026-08-26T10:00:00Z" },
              eval_row(probe: "0din.A"),
              { entry_type: "init", start_time: "2026-08-26T12:00:00Z" })

      expect(described_class.for(report).started_at).to eq(Time.zone.parse("2026-08-26T10:00:00Z"))
    end

    it "is nil when no init has been written yet" do
      journal(eval_row(probe: "0din.A"))

      expect(described_class.for(report).started_at).to be_nil
    end
  end

  describe "presence" do
    it "is false before any journal exists" do
      # Callers must not read "no journal" as "no work done": the row is also absent
      # before the first sync lands and after cleanup deletes it.
      summary = described_class.for(report)

      expect(summary.present?).to be(false)
      expect(summary.completed_probes).to be_empty
    end

    it "is true for a journal holding only attempts" do
      journal({ entry_type: "attempt", probe_classname: "0din.A", uuid: "x" })

      expect(described_class.for(report).present?).to be(true)
    end
  end

  describe "reading through SQL" do
    it "is not fooled by a prompt containing the entry_type marker" do
      # JSON escapes an inner quote as \", so a prompt quoting the marker cannot match
      # the candidate filter -- and every candidate is re-validated in Ruby anyway.
      journal({ entry_type: "attempt", uuid: "x",
                prompt: %q(here is a line: "entry_type": "eval" and a probe),
                outputs: [ "ok" ] },
              eval_row(probe: "0din.Real"))

      expect(described_class.for(report).completed_probes).to contain_exactly("0din.Real")
    end

    it "survives a malformed line" do
      raw = create(:raw_report_data, report: report, logs_data: nil,
                   jsonl_data: [ "{not json", eval_row(probe: "0din.A").to_json ].join("\n"))
      expect(raw).to be_persisted

      expect(described_class.for(report).completed_probes).to contain_exactly("0din.A")
    end
  end

  describe "caching" do
    # The test environment uses :null_store, so the cache is exercised explicitly here
    # rather than relied on implicitly.
    around do |example|
      previous = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      example.run
      Rails.cache = previous
    end

    it "does not recompute while the journal timestamp is unchanged" do
      journal(eval_row(probe: "0din.A"))
      described_class.for(report).completed_probes

      expect_any_instance_of(described_class).not_to receive(:compute_payload)
      expect(described_class.for(report).completed_probes).to contain_exactly("0din.A")
    end

    it "recomputes once the journal has been written again" do
      raw = journal(eval_row(probe: "0din.A"))
      expect(described_class.for(report).completed_probes).to contain_exactly("0din.A")

      raw.update!(jsonl_data: [ eval_row(probe: "0din.A"), eval_row(probe: "0din.B") ].map(&:to_json).join("\n"))

      expect(described_class.for(report).completed_probes).to contain_exactly("0din.A", "0din.B")
    end
  end
end
