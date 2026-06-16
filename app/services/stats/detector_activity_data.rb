module Stats
  class DetectorActivityData
    def initialize(target_id: nil, scan_id: nil, report_id: nil)
      @target_id = target_id
      @scan_id = scan_id
      @report_id = report_id
    end

    def call
      start_date = Time.zone.today - 30.days
      end_date = Time.zone.today

      rows = DetectorResult.joins(:detector, :report)
               .where(reports: { created_at: start_date.beginning_of_day..end_date.end_of_day })
      rows = rows.where(reports: { target_id: @target_id }) if @target_id.present?
      rows = rows.where(reports: { scan_id: @scan_id }) if @scan_id.present?
      rows = rows.where(report_id: @report_id) if @report_id.present?
      rows = rows.select("detectors.name, SUM(detector_results.total) AS total_tests, SUM(detector_results.passed) AS passed_tests")
                 .group("detectors.id, detectors.name")
                 .order("total_tests DESC")

      individual = []
      community = { total: 0, passed: 0, any: false }

      rows.each do |row|
        total = row.total_tests.to_i
        passed = row.passed_tests.to_i

        if row.name.to_s.start_with?("0din.")
          short_name = row.name.split(".").last
          individual << {
            name: I18n.t("detectors.names.#{short_name}", default: short_name),
            total: total,
            passed: passed
          }
        else
          community[:total] += total
          community[:passed] += passed
          community[:any] = true
        end
      end

      spokes = individual
      spokes << { name: "Community", total: community[:total], passed: community[:passed] } if community[:any]
      spokes.sort_by! { |spoke| -spoke[:total] }

      {
        detector_names: spokes.map { |spoke| spoke[:name] },
        test_counts: spokes.map { |spoke| spoke[:total] },
        passed_counts: spokes.map { |spoke| spoke[:passed] },
        time_range: "Last 30 Days"
      }
    end
  end
end
