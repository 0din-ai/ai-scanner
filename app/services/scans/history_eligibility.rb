# frozen_string_literal: true

module Scans
  # Which past reports may inform a projection.
  #
  # A projection is customer-facing, so it may only be built from runs that measured a
  # real workload to completion: a run that failed, was stopped, or dropped eval rows
  # measured less work than it planned, so feeding its totals in drags every later
  # projection of the same probes downward -- the same direction as the defect this
  # projection replaced.
  #
  # One place, so every rung of the ladder (own-run tokens, own-run duration, per-probe
  # history, the seconds-per-output rate) agrees on what counts as evidence.
  module HistoryEligibility
    module_function

    # `relation` must already reference the `reports` table -- either a Report relation or
    # something joined to it (ProbeResult.joins(:report)). Adds conditions only, never a
    # query, so callers keep their query count constant in probe count.
    def apply(relation)
      relation
        .where(reports: { status: Report.statuses[:completed] })
        # result_completeness is written on the terminal transition, so rows recorded
        # before that column existed hold NULL. A completed run with no stored value is
        # complete by virtue of having completed -- the same reading
        # Report#previous_completed_report takes. `= 'complete'` alone would discard those
        # rows, being unknown for NULL, and with them most of the tenant's history.
        .where("reports.result_completeness IS NULL OR reports.result_completeness = 'complete'")
    end
  end
end
