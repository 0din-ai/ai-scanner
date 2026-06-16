# frozen_string_literal: true

module Admin
  class DashboardController < Admin::BaseController
    def index
      skip_authorization # Dashboard is accessible to all authenticated users
      @page_title = "Dashboard"
      @period = params[:period] || "30d"

      # Single combined query for all dashboard stats (reduces 4 queries to 1)
      stats = dashboard_stats

      @has_scans = stats["total_scans"] > 0
      unless @has_scans
        render :no_scans and return
      end

      @total_scans = stats["total_scans"]
      @total_targets = stats["total_targets"]
      @total_reports = stats["total_reports"]
    end

    def get_started
      skip_authorization # same as #index; dashboard is for all authenticated users
      @page_title = "Get Started"
    end

    private

    def dashboard_stats
      company_id = current_company&.id
      return { "total_scans" => 0, "total_targets" => 0, "total_reports" => 0 } unless company_id

      ActiveRecord::Base.connection.select_one(
        ActiveRecord::Base.sanitize_sql_array([
          <<~SQL.squish, company_id, company_id, company_id, Report.statuses[:completed]
            SELECT
              (SELECT COUNT(*) FROM scans WHERE company_id = ?) AS total_scans,
              (SELECT COUNT(*) FROM targets WHERE company_id = ? AND deleted_at IS NULL) AS total_targets,
              (SELECT COUNT(*) FROM reports WHERE company_id = ? AND status = ?) AS total_reports
          SQL
        ])
      )
    end
  end
end
