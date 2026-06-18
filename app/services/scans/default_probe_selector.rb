module Scans
  # Returns the ids of the probes most successful against the current tenant's
  # own past targets, for pre-selecting on a new scan. Mirrors the dashboard
  # Stats::TopFiveAttacksData aggregation, but returns a Set of probe ids,
  # applies a minimum-attempts floor, and excludes custom probes.
  class DefaultProbeSelector
    DEFAULT_PROBE_COUNT = 10
    MIN_ATTEMPTS = 5

    def initialize(probe_scope: Probe.all, limit: DEFAULT_PROBE_COUNT, min_attempts: MIN_ATTEMPTS)
      @probe_scope = probe_scope
      @limit = limit
      @min_attempts = min_attempts
    end

    def call
      ProbeResult
        .joins(:probe)
        .where(report_id: Report.completed.select(:id))
        .where(probe_id: @probe_scope.where.not(source: "custom").select(:id))
        .group("probes.id")
        .having("SUM(probe_results.total) > 0 AND SUM(probe_results.total) >= ?", @min_attempts)
        .order(Arel.sql("SUM(probe_results.passed)::float / SUM(probe_results.total) DESC, SUM(probe_results.total) DESC, probes.id ASC"))
        .limit(@limit)
        .pluck("probes.id")
        .to_set
    end
  end
end
