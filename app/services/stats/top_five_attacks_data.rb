module Stats
  class TopFiveAttacksData
    def initialize(probe_scope: Probe.all)
      @probe_scope = probe_scope
    end

    def call
      ProbeResult
        .joins(:probe)
        .where(report_id: Report.completed.select(:id))
        .where(probe_id: @probe_scope.select(:id))
        .group("probes.id", "probes.name")
        .having("SUM(probe_results.total) > 0")
        .select(
          "probes.id AS probe_id",
          "probes.name AS probe_name",
          "SUM(probe_results.passed) AS total_passed",
          "SUM(probe_results.total) AS total_tests"
        )
        .order(Arel.sql("SUM(probe_results.passed)::float / SUM(probe_results.total) DESC, SUM(probe_results.total) DESC"))
        .limit(5)
        .map do |row|
          passed = row.total_passed.to_i
          total = row.total_tests.to_i
          {
            probe_name: row.probe_name,
            probe_id: row.probe_id,
            asr: ((passed.to_f / total) * 100).round
          }
        end
    end
  end
end
