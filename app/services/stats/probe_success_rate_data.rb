module Stats
  class ProbeSuccessRateData
    def initialize(probe_id: nil, target_id: nil, scan_id: nil, report_id: nil)
      @probe_id = probe_id
      @target_id = target_id
      @scan_id = scan_id
      @report_id = report_id
    end

    def call
      start_date = Time.zone.today - 30.days
      end_date = Time.zone.today
      scope = ProbeResult.where(created_at: start_date.beginning_of_day..end_date.end_of_day)
      scope = scope.where(probe_id: @probe_id) if @probe_id.present?
      scope = scope.joins(:report).where(reports: { target_id: @target_id }) if @target_id.present?
      scope = scope.joins(:report).where(reports: { scan_id: @scan_id }) if @scan_id.present?
      scope = scope.where(report_id: @report_id) if @report_id.present?

      total_results = scope.count

      if total_results > 0
        total_passed = scope.sum(:passed)
        total_tests = scope.sum(:total)

        # A zero denominator means nothing was measurable, not a clean 0% -- the same
        # distinction Reports::AsrFigure draws at the report level.
        success_rate = total_tests > 0 ? (total_passed.to_f / total_tests * 100).round(1) : nil

        { success_rate: success_rate, time_range: "Last 30 Days" }
      else
        { success_rate: nil, time_range: "Last 30 Days" }
      end
    end
  end
end
