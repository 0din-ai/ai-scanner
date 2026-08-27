# frozen_string_literal: true

module Scans
  # Which past reports may inform a MEASUREMENT.
  #
  # A measurement is customer-facing, so it may only be built from runs that measured a
  # real workload to completion: a run that failed, was stopped, or dropped eval rows
  # measured less work than it planned, so feeding its totals in moves the answer by how
  # much of the plan executed rather than by how the target behaved.
  #
  # One place, so every surface built on measurement agrees about what counts as
  # evidence: the projections (own-run tokens, own-run duration, per-probe history, the
  # seconds-per-output rate), the scan's aggregate figures and security grade, its ASR
  # trend, and the per-report ASR history chart.
  #
  # NOT a lifecycle question. "How many runs of this scan finished" includes partial
  # ones and must not come through here.
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
