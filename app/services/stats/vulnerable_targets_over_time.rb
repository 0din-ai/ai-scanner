# frozen_string_literal: true

module Stats
  class VulnerableTargetsOverTime
    attr_reader :days

    def initialize(days: 30)
      @days = days
    end

    def call
      targets = get_top_vulnerable_targets
      dates = generate_date_range
      time_series_data = generate_time_series_data(targets, dates)

      # Sort targets and their corresponding data by average ASR (highest to lowest)
      sorted_indices = time_series_data.each_with_index.sort_by do |target_data, _index|
        avg_asr = calculate_average_asr(target_data[:data])
        -avg_asr # Negative for descending order
      end.map(&:last)

      # Take only the top 5 after sorting by ASR
      top_5_indices = sorted_indices.first(5)
      sorted_targets = top_5_indices.map { |i| targets[i][:name] }
      sorted_data = top_5_indices.map { |i| time_series_data[i] }

      {
        targets: sorted_targets,
        dates: dates.map { |d| d.strftime("%Y-%m-%d") },
        data: sorted_data
      }
    end

    private

    def get_top_vulnerable_targets
      # Get all targets that have reports within the time period
      # We'll sort them by ASR later in the call method
      Report.joins(:target)
            .where("reports.created_at >= ?", days.days.ago)
            .group("targets.id")
            .select("targets.id, targets.name, COUNT(reports.id) as report_count")
            .order("report_count DESC")
            .limit(20) # Get more targets initially, we'll sort and limit later
            .map do |result|
              {
                id: result.id,
                name: result.name
              }
            end
    end

    def generate_date_range
      (days.days.ago.to_date..Time.zone.today).to_a
    end

    def generate_time_series_data(targets, dates)
      targets.map do |target|
        asr_by_date = {}

        # Initialize all dates with null values
        dates.each { |date| asr_by_date[date.to_s] = nil }

        # Get ASR data for each target
        # probe_results, the canonical ASR source: joining detector rows made this chart
        # rank and rate targets differently from the report pages and Average ASR.
        reports = Report.joins(:probe_results)
                        .where(target_id: target[:id])
                        .where("reports.created_at >= ?", days.days.ago)
                        .group("reports.created_at::date")
                        .select("reports.created_at::date::text as date,
                                SUM(probe_results.passed) as passed,
                                SUM(probe_results.total) as total")

        reports.each do |report|
          if report.total.to_i > 0
            asr = (report.passed.to_f / report.total * 100).round(2)
            asr_by_date[report.date.to_s] = asr
          end
        end

        {
          name: target[:name],
          data: dates.map { |date| asr_by_date[date.to_s] }
        }
      end
    end

    def calculate_average_asr(data_points)
      # Filter out null values and calculate average
      valid_points = data_points.compact
      return 0 if valid_points.empty?

      valid_points.sum.to_f / valid_points.length
    end
  end
end
