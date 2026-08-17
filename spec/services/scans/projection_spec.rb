# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scans::Projection do
  let(:company) { create(:company) }
  let(:target) { ActsAsTenant.with_tenant(company) { create(:target, company: company) } }
  let(:scan) { ActsAsTenant.with_tenant(company) { create(:complete_scan, company: company) } }

  def history_for(probe, input:, output:, evaluated: 10)
    ActsAsTenant.with_tenant(company) do
      past = create(:complete_scan, company: company)
      report = create(:report, company: company, scan: past, target: target, status: :completed)
      create(:probe_result, report: report, probe: probe,
                            input_tokens: input, output_tokens: output, total: evaluated)
    end
  end

  it "projects a probe from what it actually cost, not from its stored prompts" do
    # encoding.InjectBase64 stores no prompts at all; the static sum counted it as zero
    # while it really cost ~15k input tokens.
    probe = create(:probe, name: "encoding.InjectBase64", input_tokens: 0, prompts: [])
    history_for(probe, input: 15_140, output: 322_879)
    ActsAsTenant.with_tenant(company) { scan.probes = [ probe ]; scan.targets = [ target ] }

    projection = described_class.new(scan).call

    expect(projection.input.amount).to eq(15_140)
    expect(projection.input.basis).to eq(:measured)
  end

  it "falls back to static prompts times generations for a probe that has never run" do
    probe = create(:probe, name: "NeverRun", input_tokens: 244, prompts: [ "hi" ])
    ActsAsTenant.with_tenant(company) { scan.probes = [ probe ]; scan.targets = [ target ] }

    projection = described_class.new(scan).call

    expect(projection.input.amount).to eq(244 * Scans::Projection::GENERATIONS)
    expect(projection.input.basis).to eq(:estimated)
  end

  it "does not apply the generations multiplier to measured history" do
    # Historical probe_results already reflect the generations that run used. Applying it
    # again is the easiest way to build this wrong.
    probe = create(:probe, name: "Measured", input_tokens: 100, prompts: [ "hi" ])
    history_for(probe, input: 1_000, output: 2_000)
    ActsAsTenant.with_tenant(company) { scan.probes = [ probe ]; scan.targets = [ target ] }

    expect(described_class.new(scan).call.input.amount).to eq(1_000)
  end

  it "is unavailable when a probe has neither history nor prompts" do
    probe = create(:probe, name: "encoding.InjectHex", input_tokens: 0, prompts: [])
    ActsAsTenant.with_tenant(company) { scan.probes = [ probe ]; scan.targets = [ target ] }

    projection = described_class.new(scan).call

    expect(projection.input).not_to be_available
    expect(projection.input.basis).to eq(:unavailable)
  end

  it "reports partial coverage when only some probes can be projected" do
    measured = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
    unknown = create(:probe, name: "Unknown", input_tokens: 0, prompts: [])
    history_for(measured, input: 500, output: 600)
    ActsAsTenant.with_tenant(company) { scan.probes = [ measured, unknown ]; scan.targets = [ target ] }

    projection = described_class.new(scan).call

    expect(projection.input.covered).to eq(1)
    expect(projection.input.total).to eq(2)
  end

  it "projects output separately rather than as a multiple of input" do
    probe = create(:probe, name: "Verbose", input_tokens: 0, prompts: [])
    history_for(probe, input: 1_000, output: 8_500)
    ActsAsTenant.with_tenant(company) { scan.probes = [ probe ]; scan.targets = [ target ] }

    projection = described_class.new(scan).call

    expect(projection.output.amount).to eq(8_500)
    expect(projection.total_tokens.amount).to eq(9_500)
  end

  it "prefers this scan's own past runs over reconstructing from probes" do
    # A variant child shares its parent's scan_id, so summing a run's reports captures
    # variants, generations and per-request overhead without modelling any of them.
    probe = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
    history_for(probe, input: 1_000, output: 1_000)
    ActsAsTenant.with_tenant(company) do
      scan.probes = [ probe ]
      scan.targets = [ target ]
      # Report#input_tokens is a method over probe_results, not a column -- a run's totals
      # have to be expressed as probe_result rows.
      parent = create(:report, company: company, scan: scan, target: target, status: :completed)
      create(:probe_result, report: parent, probe: probe,
                            input_tokens: 80_000, output_tokens: 700_000, total: 400)
      child = create(:report, company: company, scan: scan, target: target,
                              status: :completed, parent_report: parent)
      create(:probe_result, report: child, probe: probe,
                            input_tokens: 4_756, output_tokens: 19_244, total: 14)
    end

    projection = described_class.new(scan).call

    expect(projection.input.amount).to eq(84_756)
    expect(projection.input.basis).to eq(:measured)
  end

  it "does not reuse its own past run once a probe has been added to the scan" do
    # AutoUpdateScanProbesJob and the ordinary edit flow both mutate a scan's probes after
    # it has run. The own-run rung reports its total as covering every CURRENT probe, so a
    # 1,000-token run followed by adding a probe with 5,000-token history kept projecting
    # 1,000 -- marked :measured over a probe the run never touched.
    ran = create(:probe, name: "Ran", input_tokens: 0, prompts: [])
    added = create(:probe, name: "AddedLater", input_tokens: 0, prompts: [])
    history_for(ran, input: 1_000, output: 1_000)
    history_for(added, input: 5_000, output: 5_000)
    ActsAsTenant.with_tenant(company) do
      scan.probes = [ ran ]
      scan.targets = [ target ]
      report = create(:report, company: company, scan: scan, target: target, status: :completed)
      create(:probe_result, report: report, probe: ran,
                            input_tokens: 1_000, output_tokens: 1_000, total: 10)
      scan.probes = [ ran, added ]
    end

    projection = described_class.new(scan).call

    # Reconstructed from per-probe history for both probes instead of the stale run total.
    expect(projection.input.amount).to eq(6_000)
    expect(projection.input.covered).to eq(2)
  end

  it "does not reuse its own past run once a probe has been removed from the scan" do
    # The other direction: the run's total includes work the scan will no longer do, so
    # presenting it as this scan's cost overstates it by whatever the removed probe cost.
    kept = create(:probe, name: "Kept", input_tokens: 0, prompts: [])
    dropped = create(:probe, name: "Dropped", input_tokens: 0, prompts: [])
    history_for(kept, input: 1_000, output: 1_000)
    ActsAsTenant.with_tenant(company) do
      scan.probes = [ kept, dropped ]
      scan.targets = [ target ]
      report = create(:report, company: company, scan: scan, target: target, status: :completed)
      create(:probe_result, report: report, probe: kept,
                            input_tokens: 1_000, output_tokens: 1_000, total: 10)
      create(:probe_result, report: report, probe: dropped,
                            input_tokens: 9_000, output_tokens: 9_000, total: 10)
      scan.probes = [ kept ]
    end

    projection = described_class.new(scan).call

    expect(projection.input.amount).not_to eq(10_000)
    expect(projection.input.amount).to eq(1_000)
  end

  it "interpolates an even-length median rather than taking the upper sample" do
    # Two runs are two samples, not a preference for the larger one. The upper middle
    # value projected 5_000 here while Scans::ProbeHistory's percentile_cont -- the rung
    # directly below this one -- would have said 2_550 for the same pair.
    probe = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
    ActsAsTenant.with_tenant(company) do
      scan.probes = [ probe ]
      scan.targets = [ target ]
      [ 100, 5_000 ].each do |amount|
        report = create(:report, company: company, scan: scan, target: target, status: :completed)
        create(:probe_result, report: report, probe: probe,
                              input_tokens: amount, output_tokens: amount, total: 10)
      end
    end

    expect(described_class.new(scan).call.input.amount).to eq(2_550)
  end

  it "does not apply a variant multiplier on top of history" do
    # An earlier draft multiplied by mapped-variant-count. Measurement showed 50 of 72
    # variant children carry their own probe_results, so those rows are already in the
    # history pool and multiplying would double-count them.
    probe = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
    history_for(probe, input: 1_000, output: 1_000)
    subindustry = create(:threat_variant_subindustry)
    create(:threat_variant, probe: probe, threat_variant_subindustry: subindustry)
    ActsAsTenant.with_tenant(company) do
      scan.probes = [ probe ]
      scan.targets = [ target ]
      scan.threat_variant_subindustries = [ subindustry ]
    end

    expect(described_class.new(scan).call.input.amount).to eq(1_000)
  end

  it "multiplies by the number of targets, because each runs the whole probe set" do
    probe = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
    history_for(probe, input: 1_000, output: 1_000)
    second = ActsAsTenant.with_tenant(company) { create(:target, company: company, name: "Second") }
    ActsAsTenant.with_tenant(company) { scan.probes = [ probe ]; scan.targets = [ target, second ] }

    expect(described_class.new(scan).call.input.amount).to eq(2_000)
  end

  it "multiplies its own past run by target count, because one run's reports are one target each" do
    # Scan#create_reports builds ONE parent report PER TARGET, so grouping past runs by
    # COALESCE(parent_report_id, id) yields one family per target and the median across
    # them is a SINGLE target's usage. The own-run rung used to return that unmultiplied,
    # so a two-target scan projected roughly half of what it costs.
    probe = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
    second = ActsAsTenant.with_tenant(company) { create(:target, company: company, name: "Second") }
    ActsAsTenant.with_tenant(company) do
      scan.probes = [ probe ]
      scan.targets = [ target, second ]
      [ target, second ].each do |tgt|
        report = create(:report, company: company, scan: scan, target: tgt, status: :completed)
        create(:probe_result, report: report, probe: probe,
                              input_tokens: 10_000, output_tokens: 20_000, total: 100)
      end
    end

    projection = described_class.new(scan).call

    expect(projection.input.amount).not_to eq(10_000)
    expect(projection.input.amount).to eq(20_000)
    expect(projection.input.basis).to eq(:measured)
  end

  it "has no total when the two halves cover different probes" do
    # Probe A is measured on both halves; probe B has prompt text but no history, so input
    # can be estimated for it and output cannot. Both aggregates end up available -- input
    # covering 2 probes, output covering 1 -- and summing them would render a confident
    # total that silently omits B's output while claiming input's coverage.
    measured = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
    prompts_only = create(:probe, name: "PromptsOnly", input_tokens: 244, prompts: [ "hi" ])
    history_for(measured, input: 1_000, output: 8_500)
    ActsAsTenant.with_tenant(company) { scan.probes = [ measured, prompts_only ]; scan.targets = [ target ] }

    projection = described_class.new(scan).call

    expect(projection.input).to be_available
    expect(projection.output).to be_available
    expect(projection.input.covered).to eq(2)
    expect(projection.output.covered).to eq(1)
    expect(projection.total_tokens).not_to be_available
  end

  it "has no total when output could not be projected" do
    # A probe with prompts but no history estimates input and cannot estimate output.
    # Adding them would render a total that silently omits the output half.
    probe = create(:probe, name: "PromptsOnly", input_tokens: 244, prompts: [ "hi" ])
    ActsAsTenant.with_tenant(company) { scan.probes = [ probe ]; scan.targets = [ target ] }

    projection = described_class.new(scan).call

    expect(projection.input).to be_available
    expect(projection.output).not_to be_available
    expect(projection.total_tokens).not_to be_available
  end

  it "totals both components when both are measured" do
    probe = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
    history_for(probe, input: 1_000, output: 8_500)
    ActsAsTenant.with_tenant(company) { scan.probes = [ probe ]; scan.targets = [ target ] }

    expect(described_class.new(scan).call.total_tokens.amount).to eq(9_500)
  end

  describe "eligible history" do
    # A probe with one legitimate 1_000-token run. percentile_cont interpolates, so any
    # second sample that leaks in moves the median off 1_000 -- these assertions fail
    # loudly rather than drifting a little.
    let(:probe) { create(:probe, name: "Measured", input_tokens: 0, prompts: []) }

    def ineligible_run(input:, &block)
      ActsAsTenant.with_tenant(company) do
        past = create(:complete_scan, company: company)
        report = create(:report, company: company, scan: past, target: target, status: :completed)
        block&.call(report)
        create(:probe_result, report: report, probe: probe,
                              input_tokens: input, output_tokens: input, total: 10)
        report
      end
    end

    before do
      history_for(probe, input: 1_000, output: 1_000)
      ActsAsTenant.with_tenant(company) { scan.probes = [ probe ]; scan.targets = [ target ] }
    end

    it "ignores a run that finished with partial results" do
      # A run that dropped eval rows measured less work than it planned; letting it set the
      # median drags every later projection of the same probes downward.
      ineligible_run(input: 999_999) { |report| report.update_columns(result_completeness: "partial") }

      expect(described_class.new(scan).call.input.amount).to eq(1_000)
    end

    it "ignores a run that failed" do
      ineligible_run(input: 999_999) { |report| report.update_columns(status: Report.statuses[:failed]) }

      expect(described_class.new(scan).call.input.amount).to eq(1_000)
    end

    it "ignores an ineligible run of THIS scan at the own-run rung too" do
      # The own-run rung is checked before per-probe history, so eligibility has to be
      # threaded through both or a partial run of this very scan sets the projection
      # outright, never reaching the history it would have been overruled by.
      ActsAsTenant.with_tenant(company) do
        report = create(:report, company: company, scan: scan, target: target, status: :completed)
        report.update_columns(result_completeness: "partial")
        create(:probe_result, report: report, probe: probe,
                              input_tokens: 999_999, output_tokens: 999_999, total: 10)
      end

      expect(described_class.new(scan).call.input.amount).to eq(1_000)
    end
  end

  describe "exclude_report_id" do
    it "projects without the report being scored, so the deviation is not measured against itself" do
      # record_all_completion_metrics runs after_update_commit, so the completed report is
      # already in the scan's own history by the time it is scored. Without exclusion,
      # own_run_tokens would find only this report, and the projection would equal the
      # very actual it's meant to be compared against.
      probe = create(:probe, name: "Measured", input_tokens: 100, prompts: [ "hi" ])
      report = ActsAsTenant.with_tenant(company) do
        scan.probes = [ probe ]
        scan.targets = [ target ]
        create(:report, company: company, scan: scan, target: target, status: :completed)
      end
      create(:probe_result, report: report, probe: probe, input_tokens: 9_999, output_tokens: 1, total: 1)

      projection = described_class.new(scan, exclude_report_id: report.id).call

      expect(projection.input.amount).not_to eq(report.input_tokens)
      # With the scored report's own history excluded and no other history for this probe,
      # projection falls back to the estimated rung: static prompt tokens * GENERATIONS.
      expect(projection.input.amount).to eq(100 * Scans::Projection::GENERATIONS)
      expect(projection.input.basis).to eq(:estimated)
    end

    it "excludes the scored report from per-probe history, not only from its own-run total" do
      # own_run_tokens and ProbeHistory are two separate queries; exclusion has to be
      # threaded through both, or a probe with no OTHER history still leaks the excluded
      # report's own probe_result back in via the history fallback rung.
      probe = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
      report = ActsAsTenant.with_tenant(company) do
        scan.probes = [ probe ]
        scan.targets = [ target ]
        create(:report, company: company, scan: scan, target: target, status: :completed)
      end
      create(:probe_result, report: report, probe: probe, input_tokens: 9_999, output_tokens: 1, total: 1)

      projection = described_class.new(scan, exclude_report_id: report.id).call

      expect(projection.input).not_to be_available
    end

    it "excludes a variant child of the scored report from both the own-run total and the history rung" do
      # A variant child shares its parent's scan_id and groups with it under
      # COALESCE(reports.parent_report_id, reports.id) in own_run_tokens, so excluding
      # only the parent id would still let the child's tokens leak into that grouped
      # total. Scans::ProbeHistory's scope applies the same id-or-parent-id exclusion, so
      # the child's own probe_result doesn't leak into the history rung either.
      probe = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
      history_for(probe, input: 1_000, output: 1_000)
      parent = ActsAsTenant.with_tenant(company) do
        scan.probes = [ probe ]
        scan.targets = [ target ]
        create(:report, company: company, scan: scan, target: target, status: :completed)
      end
      create(:probe_result, report: parent, probe: probe,
                            input_tokens: 80_000, output_tokens: 700_000, total: 400)
      child = create(:report, company: company, scan: scan, target: target,
                              status: :completed, parent_report: parent)
      create(:probe_result, report: child, probe: probe,
                            input_tokens: 4_756, output_tokens: 19_244, total: 14)

      projection = described_class.new(scan, exclude_report_id: parent.id).call

      # 84_756 (80_000 + 4_756) is what own_run_tokens would return if the child leaked
      # through -- the exact total the un-excluded "prefers this scan's own past runs"
      # test above asserts. It must not appear here.
      expect(projection.input.amount).not_to eq(84_756)
      # Nor does the child's own result (4_756) survive into the history rung -- with
      # both parent and child excluded there too, the only history left for this probe is
      # the separate historical run set up by history_for above.
      expect(projection.input.amount).to eq(1_000)
      expect(projection.input.basis).to eq(:measured)
    end
  end

  it "computes each figure once per #call, even though total_figure needs both again" do
    # #call invokes figure(:input) and figure(:output) directly, then total_figure invokes
    # both again to decide whether a total can be honestly shown. Without memoization,
    # own_run_tokens (a query) would run twice per kind on every render of the scan page.
    # A scenario where every figure resolves at the "own run" rung -- never reaching the
    # history/estimate fallback -- keeps the expected query count from depending on
    # ProbeHistory's fixture setup.
    probe = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
    ActsAsTenant.with_tenant(company) do
      scan.probes = [ probe ]
      scan.targets = [ target ]
      report = create(:report, company: company, scan: scan, target: target, status: :completed,
                              start_time: 10.minutes.ago, end_time: Time.current)
      create(:probe_result, report: report, probe: probe,
                            input_tokens: 1_000, output_tokens: 1_000, total: 10)
    end

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/ }
    projection = nil
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      projection = described_class.new(scan).call
    end

    expect(projection.input.basis).to eq(:measured)
    expect(projection.output.basis).to eq(:measured)
    expect(projection.runtime.basis).to eq(:measured)
    # own_runs, own_run_seconds -- 2 queries. It was 3 while each token kind fetched its
    # own grouped sum; own_runs now reads (run-family, probe) totals once and serves both
    # kinds, the probe-set comparison and the runtime rung's family filter from it.
    # `scan.probes = [ probe ]` above already loads the probes association in memory, so
    # the `probes.size` reads inside each figure don't add a query here; on an unloaded
    # association they'd add exactly one more (memoized after the first read), not one
    # per figure.
    expect(queries).to eq(2)
  end

  describe "runtime" do
    it "uses this scan's own past runs when it has any" do
      # The best predictor of how long a scan takes is how long it took last time.
      probe = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
      history_for(probe, input: 1_000, output: 1_000)
      ActsAsTenant.with_tenant(company) do
        scan.probes = [ probe ]
        scan.targets = [ target ]
        report = create(:report, company: company, scan: scan, target: target, status: :completed,
                                 start_time: 90.minutes.ago, end_time: Time.current)
        # The run has to record WHICH probes it ran: this rung now only reuses a duration
        # measured on the scan's current probe set, and a run with no probe_results leaves
        # no evidence of what it ran. HistoryEligibility already limits this to completed,
        # complete runs, which record their results.
        create(:probe_result, report: report, probe: probe,
                              input_tokens: 1_000, output_tokens: 1_000, total: 10)
      end

      runtime = described_class.new(scan).call.runtime

      expect(runtime.basis).to eq(:measured)
      expect(runtime.amount).to be_within(120).of(90.minutes.to_i)
    end

    it "does not reuse its own past duration once the scan's probe set has changed" do
      # Same staleness as the token rung: a duration measured on one probe set is not this
      # scan's duration after the set changed, and own_run_seconds is the only rung allowed
      # to claim :measured. It falls through to the model, which reports the coverage it
      # actually has (the added probe has no history, so it accounts for one of two).
      ran = create(:probe, name: "Ran", input_tokens: 0, prompts: [])
      added = create(:probe, name: "AddedLater", input_tokens: 0, prompts: [])
      ActsAsTenant.with_tenant(company) do
        scan.probes = [ ran ]
        scan.targets = [ target ]
        report = create(:report, company: company, scan: scan, target: target, status: :completed,
                                 start_time: 60.minutes.ago, end_time: Time.current)
        create(:probe_result, report: report, probe: ran,
                              input_tokens: 1_000, output_tokens: 1_000, total: 10)
        scan.probes = [ ran, added ]
      end

      runtime = described_class.new(scan).call.runtime

      expect(runtime.basis).to eq(:estimated)
      expect(runtime.covered).to eq(1)
      expect(runtime.total).to eq(2)
    end

    it "models runtime from evaluated outputs when the scan has never run" do
      probe = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
      ActsAsTenant.with_tenant(company) do
        other = create(:complete_scan, company: company)
        # The rate must come from a report that records BOTH its duration and how many
        # outputs it evaluated -- seconds-per-output cannot be assembled from one run's
        # clock and another run's output count.
        report = create(:report, company: company, scan: other, target: target, status: :completed,
                                 start_time: 100.seconds.ago, end_time: Time.current)
        create(:probe_result, report: report, probe: probe,
                              input_tokens: 1_000, output_tokens: 1_000, total: 100)
        scan.probes = [ probe ]
        scan.targets = [ target ]
      end

      runtime = described_class.new(scan).call.runtime

      expect(runtime).to be_available
      expect(runtime.basis).to eq(:estimated)
      expect(runtime.amount).to be_within(2).of(100)
    end

    it "sums a run's variant children into that run rather than sampling them separately" do
      # A variant child is executed work belonging to its parent's run, so a 60-minute
      # parent with a 30-minute child is a 90-minute run. Treating each report as an
      # independent duration sample took the median of [30, 60] and reported 60 -- less
      # than the work the scan actually performed.
      probe = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
      ActsAsTenant.with_tenant(company) do
        scan.probes = [ probe ]
        scan.targets = [ target ]
        parent = create(:report, company: company, scan: scan, target: target, status: :completed,
                                 start_time: 60.minutes.ago, end_time: Time.current)
        # Recorded results, so the family's probe set can be compared with the scan's.
        create(:probe_result, report: parent, probe: probe,
                              input_tokens: 1_000, output_tokens: 1_000, total: 10)
        create(:report, company: company, scan: scan, target: target, status: :completed,
                        parent_report: parent, start_time: 30.minutes.ago, end_time: Time.current)
      end

      runtime = described_class.new(scan).call.runtime

      expect(runtime.basis).to eq(:measured)
      expect(runtime.amount).to be_within(120).of(90.minutes.to_i)
    end

    it "reports only the probes its model actually accounts for" do
      # modeled_seconds sums history.values, so a probe with no history contributes zero
      # evaluated outputs and cannot move the number. Reporting probes.size covered
      # claimed the basis line had accounted for it.
      measured = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
      never_run = create(:probe, name: "NeverRun", input_tokens: 0, prompts: [])
      ActsAsTenant.with_tenant(company) do
        other = create(:complete_scan, company: company)
        report = create(:report, company: company, scan: other, target: target, status: :completed,
                                 start_time: 100.seconds.ago, end_time: Time.current)
        create(:probe_result, report: report, probe: measured,
                              input_tokens: 1_000, output_tokens: 1_000, total: 100)
        scan.probes = [ measured, never_run ]
        scan.targets = [ target ]
      end

      runtime = described_class.new(scan).call.runtime

      expect(runtime.basis).to eq(:estimated)
      expect(runtime.covered).to eq(1)
      expect(runtime.total).to eq(2)
    end

    it "is unavailable rather than zero when nothing can be modeled" do
      # The reported defect: a 13-probe scan that ran for 89 minutes displayed "0m".
      probe = create(:probe, name: "Unknown", input_tokens: 0, prompts: [])
      ActsAsTenant.with_tenant(company) { scan.probes = [ probe ]; scan.targets = [ target ] }

      expect(described_class.new(scan).call.runtime).not_to be_available
    end

    it "never divides by the concurrent-scan limit" do
      # parallel_scans_limit is how many DIFFERENT scans may run at once (20 in prod).
      # Dividing one scan's duration by it claimed the scan finishes 20x sooner.
      probe = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
      history_for(probe, input: 1_000, output: 1_000)
      ActsAsTenant.with_tenant(company) do
        scan.probes = [ probe ]
        scan.targets = [ target ]
        report = create(:report, company: company, scan: scan, target: target, status: :completed,
                                 start_time: 60.minutes.ago, end_time: Time.current)
        create(:probe_result, report: report, probe: probe,
                              input_tokens: 1_000, output_tokens: 1_000, total: 10)
      end

      allow(SettingsService).to receive(:parallel_scans_limit).and_return(20)

      expect(described_class.new(scan).call.runtime.amount).to be_within(120).of(60.minutes.to_i)
    end
  end
end
