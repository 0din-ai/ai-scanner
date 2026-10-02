# frozen_string_literal: true

require "rails_helper"

# Ingestion aggregates the judge's per-output notes into reports.judge_stats. The judge
# already acted inside garak, so the notes are evidence only: nothing about them may move
# probe_results, detector_results or the eval rows.
RSpec.describe Reports::Process, "LLM judge stats" do
  let(:target) { create(:target) }
  let(:scan) { create(:complete_scan) }
  let(:report) { create(:report, :running, target: target, scan: scan, evaluation_threshold: 0.5) }
  let(:service) { described_class.new(report.id) }
  let!(:probe) { create(:probe, name: "BoundaryProbe") }

  before do
    allow(service).to receive(:report).and_return(report)
    allow_any_instance_of(Reports::Cleanup).to receive(:call)
    allow_any_instance_of(OutputServers::Dispatcher).to receive(:call)
    allow(ToastNotifier).to receive(:call)
  end

  def entry(surface:, final:, label: nil, cache: "miss", error: nil, skipped: nil)
    { "detector" => "0din.HarmfulCompliance", "surface_score" => surface, "final_score" => final,
      "label" => label, "confidence" => (label ? 0.9 : nil), "reason" => (label ? "short reason" : nil),
      "model" => "openai/gpt-4.1-mini", "prompt_version" => "v1", "cache" => cache, "latency_ms" => 10,
      "truncated_chars" => 0, "judge_error" => error, "judge_skipped" => skipped }
  end

  # One attempt with one output per score; `notes` aligned with the outputs.
  def attempt_row(uuid, scores:, judge: nil)
    notes = judge ? { "llm_judge" => judge } : {}
    { entry_type: "attempt", probe_classname: "0din.BoundaryProbe", uuid: uuid, prompt: "p",
      outputs: scores.map { |s| "output #{s}" }, notes: notes,
      detector_results: { "0din.HarmfulCompliance" => scores } }.to_json
  end

  def eval_row(defended:, total:)
    { entry_type: "eval", detector: "0din.HarmfulCompliance", probe: "0din.BoundaryProbe",
      passed: defended, total_evaluated: total }.to_json
  end

  let(:init_row) { { entry_type: "init", start_time: "2026-01-01T10:00:00Z" }.to_json }
  let(:completion_row) { { entry_type: "completion", end_time: "2026-01-01T11:00:00Z" }.to_json }

  def run(lines)
    RawReportData.where(report_id: report.id).delete_all
    RawReportData.create!(report_id: report.id, jsonl_data: lines.join("\n"),
                          logs_data: "Garak scan completed - Exit code: 0", status: "pending")
    service.call
    report.reload
  end

  # garak's scores are already the judge's final scores; the notes record the change.
  let(:judged_lines) do
    [ init_row,
      # Demoted: detector 0.6 (success), judge REFUSED -> 0.0.
      # Kept: a provider error leaves 0.55 standing. Nil: output 2 was out of band.
      attempt_row("a1", scores: [ 0.0, 0.55, 0.9 ],
                  judge: [ entry(surface: 0.6, final: 0.0, label: "REFUSED"),
                           entry(surface: 0.55, final: 0.55, error: "timeout"),
                           nil ]),
      # The lifecycle duplicate of a1 garak writes: must not double-count.
      attempt_row("a1", scores: [ 0.0, 0.55, 0.9 ],
                  judge: [ entry(surface: 0.6, final: 0.0, label: "REFUSED"),
                           entry(surface: 0.55, final: 0.55, error: "timeout"),
                           nil ]),
      # Promoted from cache: 0.4 -> 1.0. Skipped for budget: 0.45 stands.
      attempt_row("a2", scores: [ 1.0, 0.45 ],
                  judge: [ entry(surface: 0.4, final: 1.0, label: "COMPLIED_VAGUE", cache: "hit"),
                           entry(surface: 0.45, final: 0.45, cache: nil, skipped: "budget") ]),
      eval_row(defended: 1, total: 5),
      completion_row ]
  end

  it "aggregates the notes into judge_stats" do
    processed = run(judged_lines)

    expect(processed.judge_stats).to include(
      "in_band" => 4, "judged" => 2, "demoted" => 1, "promoted" => 1, "errors" => 1,
      "skipped_budget" => 1, "cache_hits" => 1, "model" => "openai/gpt-4.1-mini", "prompt_version" => "v1"
    )
  end

  it "leaves probe and detector results exactly as garak's eval rows state them" do
    processed = run(judged_lines)
    with_notes = [ processed.probe_results.map { |r| [ r.passed, r.total, r.attempts.size ] },
                   processed.detector_results.map { |r| [ r.passed, r.total ] } ]

    # The same run with the notes stripped, through a fresh report and service.
    bare = create(:report, :running, target: target, scan: scan, evaluation_threshold: 0.5)
    bare_service = described_class.new(bare.id)
    allow(bare_service).to receive(:report).and_return(bare)
    RawReportData.create!(report_id: bare.id, status: "pending", logs_data: "Garak scan completed - Exit code: 0",
                          jsonl_data: judged_lines.map { |l| l.sub(/"notes":\{"llm_judge":.*?\]\}/, '"notes":{}') }.join("\n"))
    bare_service.call
    bare.reload

    expect(with_notes).to eq([ [ [ 4, 5, 3 ] ], [ [ 4, 5 ] ] ])
    expect([ bare.probe_results.map { |r| [ r.passed, r.total, r.attempts.size ] },
             bare.detector_results.map { |r| [ r.passed, r.total ] } ]).to eq(with_notes)
    expect(bare.judge_stats).to eq({})
  end

  it "keeps the launch status written before the run" do
    report.update_column(:judge_stats, { "launch_status" => "ready" })

    expect(run(judged_lines).judge_stats).to include("launch_status" => "ready", "in_band" => 4)
  end

  it "leaves judge_stats untouched for a run with no judge notes" do
    report.update_column(:judge_stats, { "launch_status" => "key_missing" })

    processed = run([ init_row, attempt_row("b1", scores: [ 0.6 ]), eval_row(defended: 0, total: 1), completion_row ])

    expect(processed.judge_stats).to eq("launch_status" => "key_missing")
  end

  it "records zero counters for a judge-enabled run where no output fell in the band" do
    report.update_columns(judge_config: { "enabled" => true, "model" => "m" }, judge_stats: { "launch_status" => "ready" })

    processed = run([ init_row, attempt_row("b1", scores: [ 0.9 ]), eval_row(defended: 0, total: 1), completion_row ])

    expect(processed.judge_stats).to include("launch_status" => "ready", "in_band" => 0, "judged" => 0)
  end

  it "maps the plugin's skip reasons onto their counters" do
    reasons = %w[config_error circuit_open truncated unusable]
    processed = run([ init_row,
                      attempt_row("c1", scores: [ 0.5 ] * 4,
                                  judge: reasons.map { |r| entry(surface: 0.5, final: 0.5, skipped: r) }),
                      eval_row(defended: 0, total: 4), completion_row ])

    expect(processed.judge_stats).to include("in_band" => 4, "judged" => 0, "skipped_config_error" => 1,
                                             "skipped_circuit" => 1, "skipped_truncated" => 1,
                                             "skipped_unusable" => 1)
  end

  it "ignores malformed notes rather than failing ingestion" do
    processed = run([ init_row,
                      { entry_type: "attempt", probe_classname: "0din.BoundaryProbe", uuid: "d1", prompt: "p",
                        outputs: [ "x" ], notes: { "llm_judge" => "not a list" },
                        detector_results: { "0din.HarmfulCompliance" => [ 0.6 ] } }.to_json,
                      eval_row(defended: 0, total: 1), completion_row ])

    expect(processed.status).to eq("completed")
    expect(processed.judge_stats).to eq({})
  end
end
