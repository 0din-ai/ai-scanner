# frozen_string_literal: true

module Scans
  # What a scan is likely to cost and how long it is likely to take.
  #
  # The projection this replaced was probes.sum(:input_tokens) -- each probe's stored
  # prompt text counted once. On a reported 13-probe scan that produced 598 input tokens
  # against an actual 84,756, because nine of the thirteen probes build their prompts at
  # runtime and store none. No coefficient fixes that; the only basis that works is what
  # the probes have actually cost before.
  class Projection
    # garak's own default (resources/garak.core.yaml). Scanner does not pass
    # --generations, so this is the value every scan runs under. It applies ONLY to the
    # estimated rung: measured history already includes it.
    GENERATIONS = 5

    # A run is a parent report plus any variant children, which share its scan_id. Same
    # expression Scans::ProbeHistory groups by, so both rungs agree on what one run is.
    RUN_FAMILY = Arel.sql("COALESCE(reports.parent_report_id, reports.id)")

    Result = Struct.new(:input, :output, :total_tokens, :runtime, keyword_init: true)

    # exclude_report_id: when a caller is scoring one particular report against a
    # projection (e.g. a monitoring metric evaluating that report's own actual usage),
    # that report -- and any variant children sharing its scan_id -- must be excluded
    # from every history query. Otherwise, once the report has completed, it is already
    # part of its own scan's "measured" history, and the projection it's judged against
    # is partly itself.
    def initialize(scan, exclude_report_id: nil)
      @scan = scan
      @exclude_report_id = exclude_report_id
    end

    def call
      Result.new(
        input: figure(:input),
        output: figure(:output),
        total_tokens: total_figure,
        runtime: runtime_figure
      )
    end

    private

    attr_reader :scan, :exclude_report_id

    def probes
      @probes ||= scan.probes.to_a
    end

    def history
      @history ||= ProbeHistory.for(
        company: scan.company,
        probe_ids: probes.map(&:id),
        target_id: single_target_id,
        exclude_report_id: exclude_report_id
      )
    end

    # Same-target history is preferable, but only a single-target scan has one target to
    # prefer. Multi-target scans fall back to all history.
    def single_target_id
      ids = scan.target_ids
      ids.size == 1 ? ids.first : nil
    end

    def target_multiplier
      [ scan.targets.size, 1 ].max
    end

    def contributions(kind)
      probes.map { |probe| contribution(probe, kind) }
    end

    def contribution(probe, kind)
      measured = history[probe.id]
      return [ measured[kind], :measured ] if measured

      static = probe.input_tokens.to_i
      # Only input can be estimated from prompt text; output is unknowable without history.
      return [ static * GENERATIONS, :estimated ] if kind == :input && static.positive?

      [ nil, :unavailable ]
    end

    # What each past run of THIS scan recorded, keyed by run-family: which probes it
    # measured, and what they cost. Summing a family captures variants, generations and
    # per-request overhead without modelling any of them, so this rung is checked before
    # reconstructing from per-probe history.
    #
    # NOTE: Report#input_tokens / #output_tokens are memoized Ruby methods over
    # probe_results, NOT columns. Aggregating must go through probe_results;
    # `scan.reports.sum(:input_tokens)` raises PG::UndefinedColumn.
    #
    # One query, memoized: it feeds both token kinds, the probe-set check in
    # #comparable_runs and the runtime rung's family filter, so the scan page's query
    # count stays constant in probe count. It returns one row per (run, probe) pair --
    # a few thousand on a 900-probe scan with a handful of runs -- which is the price of
    # knowing WHICH probes each run measured, and still one round trip.
    def own_runs
      @own_runs ||= exclude_scored_run(
        HistoryEligibility.apply(
          ProbeResult.joins(:report).where(reports: { scan_id: scan.id })
        )
      )
        .group(RUN_FAMILY, :probe_id)
        .pluck(RUN_FAMILY, :probe_id,
               Arel.sql("SUM(probe_results.input_tokens)"),
               Arel.sql("SUM(probe_results.output_tokens)"))
        .each_with_object({}) do |(family, probe_id, input, output), acc|
          run = acc[family] ||= { probe_ids: Set.new, input: 0, output: 0 }
          run[:probe_ids] << probe_id
          run[:input] += input.to_i
          run[:output] += output.to_i
        end
    end

    # Only a run of the probe set the scan has NOW may stand in for it. AutoUpdateScanProbesJob
    # and the ordinary edit flow both mutate a scan's probes after it has run, and this rung
    # reports its total as covering every current probe -- so a 1,000-token run followed by
    # adding a probe with 5,000-token history kept projecting 1,000, marked :measured over
    # the full set. A run that measured a probe since REMOVED is wrong in the same way, for
    # work that will not happen, so the comparison is equality rather than containment.
    #
    # Per family rather than all-or-nothing: a newer run matching the current configuration
    # still counts when an older one does not.
    def comparable_runs
      @comparable_runs ||= own_runs.select { |_family, run| run[:probe_ids] == current_probe_ids }
    end

    def current_probe_ids
      @current_probe_ids ||= probes.map(&:id).to_set
    end

    # The median is over run-families, and `Scan#create_reports` builds ONE parent report
    # PER TARGET -- so a two-target scan has two families per run and this median is one
    # target's usage, not the scan's. #build_figure applies target_multiplier to it for
    # the same reason the reconstructed rung does.
    def own_run_tokens(kind)
      totals = comparable_runs.values.map { |run| run[kind] }.select(&:positive?).sort

      median(totals)&.round
    end

    # Interpolated, matching the percentile_cont(0.5) Scans::ProbeHistory takes in
    # Postgres. The upper middle value (sorted[size / 2]) disagreed with it on every
    # even-length sample -- [100, 5_000] projected 5_000 where the rung below it would say
    # 2_550 -- and two-run or two-target histories are the common case, not an edge one.
    # One helper, used by every Ruby-side median here, so the ladder cannot disagree with
    # itself about what a median is.
    def median(sorted)
      return nil if sorted.empty?

      middle = sorted.size / 2
      return sorted[middle] if sorted.size.odd?

      (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    # The report being scored -- and any variant children sharing its scan_id, which
    # group with it under COALESCE(reports.parent_report_id, reports.id) -- must not
    # count as their own history.
    #
    # Two separate conditions, not `.where.not("id = :id OR parent_report_id = :id")`:
    # parent_report_id is NULL for every non-variant report, and SQL's three-valued logic
    # makes `NOT (FALSE OR NULL)` evaluate to NULL rather than TRUE, which a WHERE clause
    # treats as "exclude" -- that single negated OR silently dropped every unrelated
    # non-variant row in the scope, not just the report being excluded.
    def exclude_scored_run(relation)
      return relation unless exclude_report_id

      relation
        .where.not(reports: { id: exclude_report_id })
        .where("reports.parent_report_id IS NULL OR reports.parent_report_id != :id", id: exclude_report_id)
    end

    # Memoized per kind: #call computes figure(:input) and figure(:output) directly, then
    # total_figure computes both again to decide whether a total can be honestly shown.
    # The round trips underneath are memoized in their own right (#own_runs, #history), so
    # what this saves is the rebuild rather than the query -- but it is what keeps the
    # query count independent of how many times a surface asks for a figure.
    def figure(kind)
      @figures ||= {}
      @figures[kind] ||= build_figure(kind)
    end

    def build_figure(kind)
      own = own_run_tokens(kind)
      if own
        # Per-target-family median x targets, matching the reconstructed rung below. The
        # own-run rung used to return the median unmultiplied, so a two-target scan
        # projected roughly one target's usage.
        return ProjectedFigure.new(amount: own * target_multiplier, basis: :measured,
                                   covered: probes.size, total: probes.size)
      end

      rows = contributions(kind)
      known = rows.reject { |amount, _| amount.nil? }

      return ProjectedFigure.new(amount: nil, basis: :unavailable, covered: 0, total: rows.size) if known.empty?

      ProjectedFigure.new(
        amount: known.sum { |amount, _| amount } * target_multiplier,
        basis: known.all? { |_, basis| basis == :measured } ? :measured : :estimated,
        covered: known.size,
        total: rows.size
      )
    end

    def total_figure
      inputs = figure(:input)
      outputs = figure(:output)
      # A total is only honest when BOTH halves cover the SAME probes. Availability alone
      # is too weak a guard: with probe A measured and probe B carrying only prompts,
      # input covers both (A measured, B estimated) while output covers only A, because
      # output cannot be estimated from prompt text. Both halves are then available, and
      # summing them renders a confident total that silently omits B's output while
      # claiming input's larger coverage -- the exact defect this projection replaced.
      unless inputs.available? && outputs.available? && inputs.covered == outputs.covered
        return ProjectedFigure.new(amount: nil, basis: :unavailable, covered: 0, total: probes.size)
      end

      ProjectedFigure.new(
        amount: inputs.amount + outputs.amount,
        basis: inputs.measured? && outputs.measured? ? :measured : :estimated,
        covered: inputs.covered,
        total: inputs.total
      )
    end

    # modeled_seconds is always :estimated below, even when every probe's per-token
    # figures came from fully :measured history (see #figure). That's not an
    # inconsistency to fix: modeled_seconds still applies a company-wide rate (seconds
    # per evaluated output) to THIS scan's projected output count, and a rate applied to
    # a projection is weaker evidence than a recorded wall-clock duration from an actual
    # past run of this scan. Runtime only ever claims :measured from own_run_seconds, one
    # rung up -- never from a model, however well-measured its inputs.
    def runtime_figure
      own = own_run_seconds
      return ProjectedFigure.new(amount: own, basis: :measured, covered: probes.size, total: probes.size) if own

      modeled = modeled_seconds
      if modeled
        # modeled_seconds sums history.values, so ONLY probes with recorded history move
        # this number: adding a never-run probe leaves it unchanged. Claiming
        # probes.size covered made the basis line assert those probes were accounted for.
        return ProjectedFigure.new(amount: modeled, basis: :estimated,
                                   covered: history.size, total: probes.size)
      end

      ProjectedFigure.new(amount: nil, basis: :unavailable, covered: 0, total: probes.size)
    end

    # The best predictor of this scan's duration is this scan's own duration.
    #
    # Grouped by run-family exactly as #own_runs is, and summed within a family: a variant
    # child is executed work belonging to its parent's run, so a 60-minute parent with a
    # 30-minute child is a 90-minute run. Treating each report as an independent duration
    # sample took the median of 60 and 30 and reported 60.
    #
    # Restricted to #comparable_runs for the same reason the token rung is: a run of a
    # different probe set is not this scan's duration. A run that recorded no probe_results
    # at all leaves no evidence of what it ran, so it cannot be claimed as :measured for the
    # current configuration either -- HistoryEligibility already limits this to completed,
    # complete runs, which record their results.
    def own_run_seconds
      families = comparable_runs.keys.to_set
      return nil if families.empty?

      by_run = HistoryEligibility.apply(exclude_scored_run(scan.reports))
        .where.not(start_time: nil).where.not(end_time: nil)
        .pluck(RUN_FAMILY, :start_time, :end_time)
        .each_with_object(Hash.new(0)) do |(run_id, start_time, end_time), acc|
          next unless families.include?(run_id)

          acc[run_id] += (end_time - start_time).to_i
        end

      median(by_run.values.select(&:positive?).sort)&.round
    end

    # Scans are latency-bound, not throughput-bound: on a measured 79-minute run only
    # 4.1 minutes were token time. So runtime is modeled per evaluated output, never as
    # tokens divided by a target's tokens_per_second.
    def modeled_seconds
      # Targets are modelled as SERIAL, and this OVERSTATES multi-target runtime.
      #
      # StartPendingScansJob#perform limits a non-priority scan's reports by available
      # slots and then starts each one in the same pass, so a scan's per-target reports DO
      # overlap when slots allow. Two 100-second targets therefore project ~200 seconds
      # against a wall clock nearer 100.
      #
      # Kept serial for now because the honest fix is not a divisor: actual overlap
      # depends on slots free at dispatch, so it varies per run. Modelling it properly
      # belongs with the run-shape work (projecting a run -- its per-target reports and
      # their variant children -- as one unit) rather than as a coefficient here.
      # Overstating runtime is the safe direction meanwhile; the defect this replaced
      # rendered an 89-minute scan as "0m".
      outputs = history.values.sum { |row| row[:evaluated] } * target_multiplier
      return nil unless outputs.positive?

      rate = seconds_per_output
      return nil unless rate

      (outputs * rate).round
    end

    # One grouped query, not one per report: the scan page must not issue a query per
    # historical report.
    def seconds_per_output
      evaluated_by_report = exclude_scored_run(
        HistoryEligibility.apply(
          ProbeResult.joins(:report).where(reports: { company_id: scan.company_id })
        )
      )
        .group(:report_id)
        .sum(:total)

      return nil if evaluated_by_report.empty?

      durations = Report
        .where(id: evaluated_by_report.keys)
        .where.not(start_time: nil).where.not(end_time: nil)
        .pluck(:id, :start_time, :end_time)

      samples = durations.filter_map do |id, start_time, end_time|
        evaluated = evaluated_by_report[id].to_i
        seconds = (end_time - start_time).to_f
        next unless evaluated.positive? && seconds.positive?

        seconds / evaluated
      end.sort

      # Not rounded: this is a per-output rate, and #modeled_seconds rounds the product.
      median(samples)
    end
  end
end
