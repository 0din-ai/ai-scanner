# frozen_string_literal: true

require "rails_helper"

# Three separate questions -- phase, ownership, feed freshness -- deliberately not
# collapsed into one status. A run can be running and unowned (process exited, results
# queued for ingest) or owned and silent (alive but not reporting); collapsing those
# would make one of them a lie.
RSpec.describe Reports::Progress do
  let(:company) { create(:company) }
  let(:report) do
    ActsAsTenant.with_tenant(company) { create(:report, company: company, status: status) }
  end
  let(:status) { :running }

  subject(:progress) { described_class.new(report) }

  def journal(*lines)
    create(:raw_report_data, report: report, logs_data: nil,
           jsonl_data: lines.map(&:to_json).join("\n"))
  end

  def eval_row(probe:)
    { entry_type: "eval", probe: probe, detector: "detector.test", passed: 1, total_evaluated: 4 }
  end

  describe "phase" do
    context "pending" do
      let(:status) { :pending }
      it { expect(progress.phase).to eq(:queued) }
    end

    context "interrupted" do
      let(:status) { :interrupted }
      it { expect(progress.phase).to eq(:interrupted) }
    end

    context "processing" do
      let(:status) { :processing }
      it { expect(progress.phase).to eq(:finalizing) }
    end

    context "completed" do
      let(:status) { :completed }

      it "is finished and stops polling" do
        expect(progress.phase).to eq(:finished)
        expect(progress.poll?).to be(false)
        expect(progress.in_flight?).to be(false)
      end
    end

    context "starting" do
      let(:status) { :starting }

      it "is starting while it is still fresh" do
        report.update_columns(updated_at: Time.current)
        expect(progress.phase).to eq(:starting)
      end

      it "is stalled once it has been claimed too long without running" do
        report.update_columns(updated_at: 10.minutes.ago)
        expect(progress.phase).to eq(:stalled)
      end
    end

    context "running with a live heartbeat" do
      it "is running" do
        report.update_columns(pid: 123, heartbeat_at: Time.current)
        expect(progress.phase).to eq(:running)
      end
    end

    context "running with a silent heartbeat" do
      it "is stalled" do
        report.update_columns(pid: 123, heartbeat_at: 10.minutes.ago)
        expect(progress.phase).to eq(:stalled)
      end
    end

    context "running with no owning process" do
      before { report.update_columns(pid: nil, heartbeat_at: 10.minutes.ago, updated_at: 10.minutes.ago) }

      it "is finalizing while its results are queued for ingest" do
        # A finished scan looks exactly like an orphan until ProcessReportJob runs.
        # Telling a user their completed scan is stuck is worse than saying nothing.
        allow(Reports::StallDetection).to receive(:awaiting_processing).and_return(:yes)

        expect(progress.phase).to eq(:finalizing)
      end

      it "says so plainly when the queue cannot be read" do
        # Neither answer is earned from a failed query: guessing finalizing would hide a
        # real stall behind a reassuring label, and guessing stalled would raise a false
        # alarm. Polling continues, because not knowing is a reason to ask again.
        allow(Reports::StallDetection).to receive(:awaiting_processing).and_return(:unknown)

        expect(progress.phase).to eq(:unknown)
        expect(progress.poll?).to be(true)
      end

      it "is stalled when nothing is queued to pick it up" do
        allow(Reports::StallDetection).to receive(:awaiting_processing).and_return(:no)

        expect(progress.phase).to eq(:stalled)
      end
    end
  end

  describe "stall reason" do
    it "describes what was observed, not a cause it cannot see" do
      report.update_columns(pid: 123, heartbeat_at: 10.minutes.ago)

      # Not "the process died" -- we know no heartbeat arrived, not why.
      expect(progress.stall_reason).to eq("This scan has stopped reporting activity.")
    end

    it "is absent when the run is healthy" do
      report.update_columns(pid: 123, heartbeat_at: Time.current)

      expect(progress.stall_reason).to be_nil
    end
  end

  describe "the ratio" do
    before { report.update_columns(pid: 123, heartbeat_at: Time.current) }

    it "is stated when both halves are real" do
      report.update_columns(planned_probe_count: 4)
      journal(eval_row(probe: "0din.A"), eval_row(probe: "0din.B"))

      expect(progress.determinate?).to be(true)
      expect(progress.completed_units).to eq(2)
      expect(progress.percent_complete).to eq(50)
    end

    it "is withheld when no plan was recorded" do
      # Inventing a denominator would be worse than showing completed work alone.
      journal(eval_row(probe: "0din.A"))

      expect(progress.determinate?).to be(false)
      expect(progress.percent_complete).to be_nil
      expect(progress.completed_units).to eq(1)
    end

    it "is withheld before any journal exists" do
      report.update_columns(planned_probe_count: 4)

      expect(progress.determinate?).to be(false)
    end

    it "cannot exceed 100" do
      # A resumed run can re-evaluate a probe the plan did not anticipate.
      report.update_columns(planned_probe_count: 1)
      journal(eval_row(probe: "0din.A"), eval_row(probe: "0din.B"))

      expect(progress.percent_complete).to eq(100)
    end
  end

  describe "the unit" do
    it "is probes for an ordinary report" do
      expect(progress.unit).to eq("probe")
    end

    it "is variants for a variant child, whose plan counts variants" do
      allow(report).to receive(:is_variant_report?).and_return(true)

      expect(progress.unit).to eq("variant")
    end
  end

  describe "feed freshness" do
    it "is unknown when nothing has ever been heard" do
      expect(progress.feed_state).to eq(:unknown)
    end

    it "is fresh on a recent heartbeat" do
      report.update_columns(heartbeat_at: 5.seconds.ago)
      expect(progress.feed_state).to eq(:fresh)
    end

    it "is stale on an old one" do
      report.update_columns(heartbeat_at: 10.minutes.ago)
      expect(progress.feed_state).to eq(:stale)
    end
  end

  describe "the representation key" do
    before { report.update_columns(pid: 123, heartbeat_at: Time.current, planned_probe_count: 4) }

    it "changes when completed work changes" do
      journal(eval_row(probe: "0din.A"))
      before_key = described_class.new(report).representation_key

      report.raw_report_data.update!(
        jsonl_data: [ eval_row(probe: "0din.A"), eval_row(probe: "0din.B") ].map(&:to_json).join("\n")
      )

      expect(described_class.new(report.reload).representation_key).not_to eq(before_key)
    end

    it "does not change across a poll interval when nothing has happened" do
      # The card renders elapsed time as "6 minutes", so a key that moved every few
      # seconds would make every poll a 200 carrying an identical card -- the
      # conditional response switched off while looking like it works.
      journal(eval_row(probe: "0din.A"))
      now = Time.current

      expect(described_class.new(report, now: now + 5.seconds).representation_key)
        .to eq(described_class.new(report, now: now).representation_key)
    end

    it "changes exactly when the displayed elapsed text does" do
      # distance_of_time_in_words rounds at 30, 90, 150 seconds. A plain per-minute
      # bucket would give 89s and 90s the same key while they render "1 minute" and
      # "2 minutes" -- a 304 carrying text the card has outgrown.
      journal(eval_row(probe: "0din.A"))
      started = report.created_at

      at = ->(seconds) { described_class.new(report, now: started + seconds) }

      expect(at.call(89).elapsed_label).not_to eq(at.call(90).elapsed_label)
      expect(at.call(89).representation_key).not_to eq(at.call(90).representation_key)
      expect(at.call(91).representation_key).to eq(at.call(90).representation_key)
    end

    it "changes on a transition driven only by the clock" do
      # Crossing the stall threshold writes nothing to the database, so a key derived
      # from updated_at would serve a stale card indefinitely.
      journal(eval_row(probe: "0din.A"))
      healthy = described_class.new(report, now: Time.current).representation_key

      expect(described_class.new(report, now: 1.hour.from_now).representation_key).not_to eq(healthy)
    end
  end
end
