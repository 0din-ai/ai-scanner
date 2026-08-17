# frozen_string_literal: true

module Scans
  # What each probe has actually cost this tenant before.
  #
  # This is the only honest basis for probes that build their prompts at runtime --
  # encoding.Inject*, av_spam_scanning.*, divergence.Repeat and friends store no prompt
  # text at all, so the static projection counted them as zero while they produced most
  # of the real cost.
  #
  # Median rather than mean: the most expensive probes have the fewest runs, and one
  # outlier run would otherwise dominate the projection.
  #
  # The median is over RUNS of a probe, not over probe_result rows. A run is a parent
  # report plus any variant children, which share its scan_id -- and a variant child
  # records its own probe_result row against the SAME base probe as its parent. Taking
  # percentile_cont across individual rows therefore let a family of one 100-token parent
  # row and ten 20-token variant rows read as ~20, when that family actually cost 300.
  # Scans::Projection deliberately applies no variant multiplier (variant rows are meant
  # to be represented in history already), so that error passed straight through and
  # underprojected variant-carrying scans by orders of magnitude.
  class ProbeHistory
    # Same grouping Scans::Projection uses for a scan's own runs, so both rungs of the
    # ladder agree on what one run is.
    RUN_FAMILY = "COALESCE(reports.parent_report_id, reports.id)"

    # Written out rather than built by interpolation: every column here is a literal, but
    # a lambda that interpolates its argument reads as user-controlled SQL to Brakeman,
    # and an ignore entry would silence the check rather than satisfy it.
    MEDIAN_SELECT = <<~SQL.squish.freeze
      probe_results.probe_id,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY probe_results.input_tokens),
      percentile_cont(0.5) WITHIN GROUP (ORDER BY probe_results.output_tokens),
      percentile_cont(0.5) WITHIN GROUP (ORDER BY probe_results.total)
    SQL

    def self.for(company:, probe_ids:, target_id: nil, exclude_report_id: nil)
      new(company: company, probe_ids: probe_ids, target_id: target_id, exclude_report_id: exclude_report_id).call
    end

    def initialize(company:, probe_ids:, target_id: nil, exclude_report_id: nil)
      @company = company
      @probe_ids = Array(probe_ids)
      @target_id = target_id
      @exclude_report_id = exclude_report_id
    end

    def call
      return {} if @probe_ids.empty?

      # No target to prefer: the tenant-wide query alone is both rungs at once, so this
      # stays the one query it always was.
      return medians_for(target_scoped: false) unless @target_id

      # Same-target history is stronger evidence (token counts vary with model verbosity),
      # so it must win where it exists -- but a probe with no same-target sample is not a
      # probe with no evidence: the tenant-wide query is the fallback for exactly that
      # probe. `merge` keeps the same-target value wherever both queries have one.
      medians_for(target_scoped: false).merge(medians_for(target_scoped: true))
    end

    private

    def medians_for(target_scoped:)
      rows = median_across_runs(target_scoped: target_scoped).pluck(Arel.sql(MEDIAN_SELECT))

      rows.each_with_object({}) do |(probe_id, input, output, evaluated), acc|
        # basis is :measured either way -- a tenant-wide fallback is still real recorded
        # usage, just against a different target than the one being scanned. It is weaker
        # evidence than a same-target sample (see the class comment), but the caller's
        # ladder has only :measured/:estimated/:unavailable, and "measured against some
        # other target" is closer to :measured than to a static-prompt :estimated.
        acc[probe_id] = { input: input.to_i, output: output.to_i, evaluated: evaluated.to_i }
      end
    end

    # Aggregate first, then take the median: one subquery sums each (run-family, probe)
    # pair, and the outer query takes percentile_cont ACROSS those per-run totals. Still a
    # single round trip -- a per-probe loop would issue 900+ queries on a real scan.
    #
    # The subquery is aliased `probe_results` so its summed columns keep the names the
    # outer query, MEDIAN_SELECT and `group(:probe_id)` already use; ProbeResult carries no
    # default scope, so nothing else is silently qualified against the real table.
    def median_across_runs(target_scoped:)
      totals_per_run = scope(target_scoped: target_scoped)
        .group(Arel.sql(RUN_FAMILY), :probe_id)
        .select(Arel.sql(
          "probe_results.probe_id AS probe_id, " \
          "SUM(probe_results.input_tokens) AS input_tokens, " \
          "SUM(probe_results.output_tokens) AS output_tokens, " \
          "SUM(probe_results.total) AS total"
        ))

      ProbeResult.from(Arel.sql("(#{totals_per_run.to_sql}) AS probe_results")).group(:probe_id)
    end

    def scope(target_scoped:)
      # ProbeResult carries no company_id; the join is what scopes this to the tenant --
      # for BOTH the same-target and the tenant-wide query, so the fallback that widens
      # the query never widens it past this tenant.
      #
      # HistoryEligibility is what keeps failed and partial runs out of a customer-facing
      # projection -- without it a scan that died a third of the way through sets the
      # median every later scan is projected from. Same rule as every other rung of
      # Scans::Projection's ladder.
      relation = HistoryEligibility.apply(
        ProbeResult.joins(:report).where(reports: { company_id: @company.id })
      )
        .where(probe_id: @probe_ids)
        # Row-level, applied before the per-run sums below: a row that recorded no input
        # measured nothing, and dropping it from its run's total is the same reading the
        # unaggregated query took.
        .where("probe_results.input_tokens > 0")

      relation = relation.where(reports: { target_id: @target_id }) if target_scoped
      # A caller scoring one particular report (e.g. a monitoring metric evaluating that
      # report's actual usage) must see history as of before that report existed, or its
      # own results would silently become part of the basis it's being judged against.
      # Matches Scans::Projection#own_run_tokens: a variant child shares its parent's
      # scan_id and would otherwise leave the parent's own results back in through the
      # child's row, so both the report and its children are excluded together.
      #
      # Two separate conditions, not one negated OR: parent_report_id is NULL for every
      # non-variant report, and `NOT (id = :id OR parent_report_id = :id)` evaluates to
      # NULL (excluded by WHERE) for any such row via SQL's three-valued logic, not just
      # for the report being excluded.
      if @exclude_report_id
        relation = relation
          .where.not(reports: { id: @exclude_report_id })
          .where("reports.parent_report_id IS NULL OR reports.parent_report_id != :id", id: @exclude_report_id)
      end
      relation
    end
  end
end
