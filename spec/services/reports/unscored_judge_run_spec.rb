# frozen_string_literal: true

require "rails_helper"

# What a report becomes when an LLM judge never returned a usable verdict.
#
# The vendored garak patch (script/garak_plugins/detectors/_judge.py) records an
# unparseable judge reply as unscored rather than as a successful attack. garak
# then counts those as neither pass nor fail (evaluators/base.py), so the probe
# reports total_evaluated: 0 -- and GarakEvalRowValidator rejects a row with a
# non-positive total, so no probe result is persisted at all.
#
# That is a deliberately conservative outcome, but it means the honest answer is
# "this run measured nothing", not "this run found nothing". These pin which one
# the report actually says, end to end through real ingestion rather than by
# constructing a probe result the pipeline could never produce.
RSpec.describe Reports::Process, "when the judge returned no usable verdict" do
  let(:target) { create(:target) }
  let(:scan) { create(:complete_scan) }
  let(:report) { create(:report, :running, target: target, scan: scan, uuid: "unscored-uuid") }
  let(:service) { described_class.new(report.id) }
  let!(:probe) { create(:probe, name: "JudgedProbe") }
  let!(:other_probe) { create(:probe, name: "ScoredProbe") }

  before do
    allow(service).to receive(:report).and_return(report)
    allow_any_instance_of(Reports::Cleanup).to receive(:call)
    allow_any_instance_of(OutputServers::Dispatcher).to receive(:call)
    allow(ToastNotifier).to receive(:call)
  end

  REFUSAL = "I cannot help with that."
  COMPLIANCE = "Certainly. Step one is to gather the following materials."

  # One garak attempt row. `score` is what the detector returned for the single
  # output: 0.0 defended, 1.0 the attack got through, nil the judge gave no
  # usable verdict. The output text is chosen to match the score so the fixture
  # does not assert something the evidence contradicts.
  def attempt_row(probe_name, uuid, score:)
    output = score == 1.0 ? COMPLIANCE : REFUSAL
    { entry_type: "attempt", probe_classname: "0din.#{probe_name}", uuid: uuid,
      prompt: "how is it made?", outputs: [ output ],
      detector_results: { "judge.Refusal" => [ score ] } }.to_json
  end

  # A probe's worth of attempts, `defended` of `total` of which the model held.
  def attempt_rows(probe_name, defended:, total:)
    (0...total).map do |i|
      attempt_row(probe_name, "#{probe_name}-#{i}", score: i < defended ? 0.0 : 1.0)
    end
  end

  # `passed` in a garak eval row counts attempts the model DEFENDED, which
  # Reports::Process inverts into successful attacks. Named here so these
  # fixtures read as what garak actually emits.
  def eval_row(probe_name, defended:, total:)
    { entry_type: "eval", detector: "judge.Refusal", probe: "0din.#{probe_name}",
      passed: defended, total_evaluated: total }.to_json
  end

  def run(lines, logs: "Garak scan completed - Exit code: 0")
    RawReportData.where(report_id: report.id).delete_all
    RawReportData.create!(report_id: report.id, jsonl_data: lines.join("\n"),
                          logs_data: logs, status: "pending")
    service.call
    report.reload
  end

  let(:init_row) { { entry_type: "init", start_time: "2026-01-01T10:00:00Z" }.to_json }
  let(:completion_row) { { entry_type: "completion", end_time: "2026-01-01T11:00:00Z" }.to_json }

  context "when every probe went unscored" do
    subject(:processed) do
      run([ init_row,
            attempt_row("JudgedProbe", "j0", score: nil),
            attempt_row("JudgedProbe", "j1", score: nil),
            eval_row("JudgedProbe", defended: 0, total: 0), completion_row ])
    end

    it "persists no probe result, because a zero-total eval row is rejected" do
      expect(processed.probe_results).to be_empty
    end

    it "does not claim an attack success rate" do
      # The distinction this whole type exists for: nothing was measured, so no
      # rate can be stated. 0% would read as a target that defended everything.
      expect(processed.asr.calculable?).to be(false)
      expect(processed.asr.percent).to be_nil
    end

    it "reports that it holds no results" do
      expect(processed.result_completeness).to eq("none")
    end

    it "does not present the run as a completed measurement" do
      expect(processed.status).to eq("failed")
    end
  end

  context "when one probe scored and another went unscored" do
    subject(:processed) do
      run([ init_row,
            attempt_row("JudgedProbe", "j0", score: nil),
            *attempt_rows("ScoredProbe", defended: 3, total: 4),
            eval_row("JudgedProbe", defended: 0, total: 0),
            eval_row("ScoredProbe", defended: 3, total: 4),
            completion_row ])
    end

    it "keeps only the probe that was actually evaluated" do
      expect(processed.probe_results.map { |r| r.probe.name }).to eq([ "ScoredProbe" ])
    end

    it "states a rate over what was measured, not over what was attempted" do
      # One of four attempts got through on the probe that was evaluated; the
      # unscored probe contributes nothing rather than diluting the rate.
      expect(processed.asr.percent).to eq(25.0)
    end

    it "marks the run as holding only part of its results" do
      # The unscored probe is missing from the report, and the report has to say
      # so rather than presenting 25% as the whole picture.
      expect(processed.result_completeness).to eq("partial")
    end

    it "still completed, because usable results were produced" do
      expect(processed.status).to eq("completed")
    end

    it "records a verdict per attempt that agrees with the probe's counts" do
      # The check the earlier fixture could not make: three attempts defended and
      # one through, matching the 3-of-4 eval row and the 25% rate above.
      attempts = processed.probe_results.sole.attempts

      expect(attempts.count { |a| a["attack_succeeded"] == true }).to eq(1)
      expect(attempts.count { |a| a["attack_succeeded"] == false }).to eq(3)
    end
  end

  context "when one probe scored some of its outputs and not others" do
    # The middle case, and the only one where unscored attempts survive into the
    # report: garak scored two of the four and counted the other two as neither
    # pass nor fail, so total_evaluated is 2, the row is accepted, and the probe
    # is persisted with all four attempts as evidence.
    subject(:processed) do
      run([ init_row,
            attempt_row("ScoredProbe", "s0", score: 0.0),
            attempt_row("ScoredProbe", "s1", score: 0.0),
            attempt_row("ScoredProbe", "s2", score: nil),
            attempt_row("ScoredProbe", "s3", score: nil),
            eval_row("ScoredProbe", defended: 2, total: 2),
            completion_row ])
    end

    it "persists the probe, because something was evaluated" do
      expect(processed.probe_results.sole.probe.name).to eq("ScoredProbe")
    end

    it "keeps the unscored attempts as evidence alongside the scored ones" do
      # The prompts and responses are real and worth reading even where no
      # verdict could be reached, so they are retained rather than discarded.
      expect(processed.probe_results.sole.attempts.size).to eq(4)
    end

    it "gives a verdict only to the attempts that were actually scored" do
      verdicts = processed.probe_results.sole.attempts.map { |a| a["attack_succeeded"] }

      expect(verdicts.count { |v| v == false }).to eq(2)
      expect(verdicts.count(&:nil?)).to eq(2)
    end

    it "states its rate over the two that were evaluated" do
      expect(processed.asr.percent).to eq(0.0)
      expect(processed.probe_results.sole.total).to eq(2)
    end
  end

  context "when attacks were evaluated and all were blocked" do
    it "still reports a real zero" do
      # The case the examples above must not swallow: 0% is a genuine result and
      # is not the same as "not measurable".
      processed = run([ init_row, *attempt_rows("JudgedProbe", defended: 3, total: 3),
                        eval_row("JudgedProbe", defended: 3, total: 3), completion_row ])

      expect(processed.asr.calculable?).to be(true)
      expect(processed.asr.percent).to eq(0.0)
      expect(processed.probe_results.sole.attempts.map { |a| a["attack_succeeded"] })
        .to all(be(false))
    end
  end

  describe "the per-attempt verdict" do
    it "is nil when every detector score is nil" do
      # nil is a third state, not a false: the judge did not answer, so neither
      # "succeeded" nor "blocked" is a claim that can be made.
      expect(service.send(:attempt_attack_succeeded, { "judge.Refusal" => [ nil, nil ] })).to be_nil
    end

    it "is still decided when only some scores are nil" do
      expect(service.send(:attempt_attack_succeeded, { "judge.Refusal" => [ nil, 1.0 ] })).to be(true)
    end

    it "records no detector score for a detector that returned only nils" do
      expect(service.send(:attempt_detector_scores, { "judge.Refusal" => [ nil, nil ] })).to eq({})
    end
  end
end
