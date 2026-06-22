module Stats
  class AverageAsrScore < ApplicationService
    DEFAULT_WINDOW = 30.days.freeze

    SQL_SUCCESS_RATE = "(SUM(probe_results.passed)::float / SUM(probe_results.total)::float * 100)".freeze
    TIME_GROUP_FORMATS = {
      "week" => "TO_CHAR(reports.created_at, 'IYYY-IW')",
      "month" => "TO_CHAR(reports.created_at, 'YYYY-MM')",
      "day" => "reports.created_at::date"
    }.freeze

    def initialize(days: DEFAULT_WINDOW)
      @threshold = days.days.ago
    end

    # Returns: { score: (Float), data: { dates: [...], rates: [...] } }
    def call
      generate_response(
        average_attack_success_rate(@threshold),
        average_attack_success_rate_over_time(@threshold)
      )
    end

    def average_attack_success_rate(since_date = nil)
      # Calculate average in SQL using subquery to avoid fetching all rates to Ruby
      # Previous: fetched N rows, averaged in Ruby. Now: single SQL AVG()
      date_condition = since_date ? "AND reports.created_at >= :since_date" : ""

      # SECURITY: raw SQL bypasses acts_as_tenant's default scope, so we MUST filter by
      # the current tenant's company_id explicitly. Fail closed (no tenant => no rows => 0).
      company_id = ActsAsTenant.current_tenant&.id

      sql = <<~SQL.squish
        SELECT AVG(per_report_rate) as avg FROM (
          SELECT (SUM(probe_results.passed)::float / NULLIF(SUM(probe_results.total), 0)::float * 100) as per_report_rate
          FROM reports
          INNER JOIN probe_results ON probe_results.report_id = reports.id
          WHERE probe_results.total > 0 AND reports.company_id = :company_id #{date_condition}
          GROUP BY reports.id
        ) subquery
      SQL

      result = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ sql, { since_date: since_date, company_id: company_id } ])
      )
      (result.to_f || 0).round(2)
    end

    def average_attack_success_rate_over_time(since_date = nil, interval = "day")
      since_date ||= DEFAULT_WINDOW.ago
      start_date = since_date.to_date
      end_date = Time.zone.today

      actual_rates = time_series_success_rates(since_date, interval)
      date_series = date_series_for_interval(start_date, end_date, interval)
      time_series = build_time_series_with_defaults(date_series, actual_rates)

      {
        dates: time_series.map { |item| item[:date].to_s },
        rates: time_series.map { |item| item[:success_rate] }
      }
    end

    private

    def generate_response(score = nil, data = {})
      { score: score, data: data }
    end

    def time_series_success_rates(since_date, interval)
      query = base_report_query(since_date)
      time_group = time_grouping_for_interval(interval)

      query.group(time_group)
           .order(time_group)
           .select([ time_group.as("time_period"), success_rate_sql_expression.as("success_rate") ])
           .to_a
           .each_with_object({}) do |result, hash|
        hash[format_time_period(result.time_period, interval)] = result.success_rate.round(2)
      end
    end

    def build_time_series_with_defaults(date_series, actual_data)
      date_series.map do |date|
        {
          date: date,
          success_rate: actual_data[date] || 0.0
        }
      end
    end

    def base_report_query(since_date)
      # SECURITY: fail closed on a missing tenant. acts_as_tenant returns ALL rows when
      # current_tenant is nil, which would leak the time series across tenants — so scope
      # by company_id explicitly (nil => no rows), mirroring the scalar average.
      query = Report.where(company_id: ActsAsTenant.current_tenant&.id)
                    .joins(:probe_results).where("probe_results.total > 0")
      since_date.present? ? query.where("reports.created_at >= ?", since_date) : query
    end

    def success_rate_sql_expression
      Arel.sql(SQL_SUCCESS_RATE)
    end

    def time_grouping_for_interval(interval)
      Arel.sql(TIME_GROUP_FORMATS[interval.to_s.downcase] || TIME_GROUP_FORMATS["day"])
    end

    def format_time_period(time_period, interval)
      interval.to_s.downcase == "week" && time_period.include?("-") ?
        period_to_week_label(time_period) : time_period
    end

    def period_to_week_label(time_period)
      year, week = time_period.split("-")
      "#{year}-Week #{week}"
    end

    def date_series_for_interval(start_date, end_date, interval)
      case interval.to_s.downcase
      when "week"
        weekly_date_series(start_date, end_date)
      when "month"
        monthly_date_series(start_date, end_date)
      else
        # default to 'day'
        (start_date..end_date).to_a
      end
    end

    def weekly_date_series(start_date, end_date)
      current = start_date.beginning_of_week
      [].tap do |weeks|
        while current <= end_date
          weeks << "#{current.cwyear}-Week #{current.strftime('%V')}"
          current += 1.week
        end
      end
    end

    def monthly_date_series(start_date, end_date)
      current = start_date.beginning_of_month
      [].tap do |months|
        while current <= end_date
          months << current.strftime("%Y-%m")
          current += 1.month
        end
      end
    end
  end
end
