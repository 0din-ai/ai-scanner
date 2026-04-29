# frozen_string_literal: true

module Admin
  class ReportsController < Admin::BaseController
    # probes_tab and attempt_content load @report with custom includes — excluded intentionally
    before_action :set_report, only: [ :show, :destroy, :stop, :asr_history, :top_probes ]
    before_action :set_debug_lease_report, only: [ :refresh_debug_lease ]

    include TargetsHelper

    def index
      authorize Report
      @page_title = "Reports"
      @scope = params[:scope] || "all"

      # Build base scope based on selected tab
      base_scope = case @scope
      when "completed" then Report.completed
      when "failed" then Report.failed
      when "running" then Report.running
      when "pending" then Report.pending
      when "starting" then Report.starting
      when "interrupted" then Report.interrupted
      when "variants" then Report.child_reports_only.includes(:parent_report)
      else Report.parent_reports
      end

      # Apply optional scan filter if coming from scan page
      base_scope = base_scope.where(scan_id: params[:scan_id]) if params[:scan_id]

      # Apply ransack search with pre-calculated detector stats to avoid N+1 queries
      @q = base_scope.includes(:target, :scan).with_detector_stats.ransack(params[:q])
      @pagy, @reports = pagy(apply_sorting(@q.result))

      # Calculate scope counts for tabs
      count_base = params[:scan_id] ? Scan.find(params[:scan_id]).reports : Report
      @scope_counts = {
        all: count_base.parent_reports.count,
        completed: count_base.parent_reports.completed.count,
        failed: count_base.parent_reports.failed.count,
        running: count_base.parent_reports.running.count,
        pending: count_base.parent_reports.pending.count,
        starting: count_base.parent_reports.starting.count,
        interrupted: count_base.parent_reports.interrupted.count,
        variants: Report.child_reports_only.count
      }

      # Load filter options
      @filter_targets = Target.order(:name).pluck(:name, :id)
    end

    def show
      authorize @report
      @page_title = "Report ##{@report.id}"
      # Activity Stream leases are refreshed by the mounted lease controller.
    end

    def destroy
      authorize @report
      @report.destroy
      redirect_to reports_path(preserve_params), notice: "Report was successfully deleted.", status: :see_other
    end

    # Member action: stop a single report
    def stop
      authorize @report
      Reports::Stop.new(@report).call
      redirect_back(fallback_location: report_path(@report), notice: "Report stopped successfully.")
    end

    # Unified batch action dispatcher (for shared table component)
    def batch
      authorize Report, :index?
      case params[:batch_action]
      when "stop"
        batch_stop
      when "destroy"
        batch_destroy
      else
        redirect_to reports_path(preserve_params), alert: "Unknown batch action"
      end
    end

    # Batch action: stop multiple reports
    def batch_stop
      ids = params[:ids] || []
      Report.where(id: ids).find_each do |report|
        Reports::Stop.new(report).call
      end
      redirect_to reports_path(preserve_params), notice: "Selected reports have been stopped."
    end

    # Batch action: destroy multiple reports
    def batch_destroy
      ids = params[:ids] || []
      count = Report.where(id: ids).destroy_all.count
      redirect_to reports_path(preserve_params), notice: "#{count} reports were successfully deleted.", status: :see_other
    end

    # JSON endpoint for ASR history chart
    def asr_history
      authorize @report
      # Get ASR history for this scan - last 10 reports or current report if alone
      # with_detector_stats provides cached_passed/cached_total to avoid N+1 on attack_success_rate
      reports = Report.where(scan_id: @report.scan_id)
                      .where(status: :completed)
                      .with_detector_stats
                      .order(created_at: :desc)
                      .limit(10)
                      .reverse

      # If no reports, return empty data
      if reports.empty?
        render json: { dates: [], asr_values: [], successful_attacks: [] }
        return
      end

      dates = []
      asr_values = []
      successful_attacks = []

      reports.each do |report|
        dates << report.created_at.strftime("%m/%d")
        asr_values << report.attack_success_rate.round(1)
        successful_attacks << report.total_successful_attacks
      end

      render json: {
        dates: dates,
        asr_values: asr_values,
        successful_attacks: successful_attacks
      }
    end

    # Probes tab content loaded via Turbo Frame
    def probes_tab
      scan_includes = if Scan.reflect_on_association(:threat_variant_subindustries)
        { scan: :threat_variant_subindustries }
      else
        :scan
      end

      @report = Report.includes(:child_report, scan_includes).find(params[:id])
      authorize @report
      @probe_results = @report.probe_results.for_report_probe_cards.to_a
      render layout: false
    end

    # Probe attempt rows loaded on demand from each probe card.
    def probe_attempts
      @report = Report.includes(:child_report).find(params[:id])
      authorize @report

      @probe_result = @report.probe_results.find(params[:probe_result_id])

      raw_probe_index = params[:probe_index].to_s
      if params.key?(:probe_index) && !raw_probe_index.match?(/\A\d+\z/)
        head :bad_request
        return
      end
      @probe_index = raw_probe_index.match?(/\A\d+\z/) ? raw_probe_index.to_i : 0

      @attempt_items = @report.all_attempts_for_probe(@probe_result)

      render layout: false
    end

    # Attempt prompt/response content loaded via Turbo Frame on card expand
    def attempt_content
      @report = Report.includes(:child_report).find(params[:id])
      authorize @report

      probe_result = @report.probe_results.find(params[:probe_result_id])
      raw_index = params[:attempt_index]
      unless raw_index&.match?(/\A\d+\z/)
        head :bad_request
        return
      end
      attempt_index = raw_index.to_i

      if @report.has_variant_data?
        all_attempts = @report.all_attempts_for_probe(probe_result)
        item = all_attempts[attempt_index]
      else
        attempts = probe_result.attempts || []
        raw_attempt = attempts[attempt_index]
        item = raw_attempt ? { attempt: raw_attempt, variant_industry: nil } : nil
      end

      if item.nil?
        Rails.logger.warn(
          "[attempt_content] No attempt found for report=#{@report.id} " \
          "probe_result=#{probe_result.id} index=#{attempt_index} " \
          "has_variant_data=#{@report.has_variant_data?}"
        )
        head :not_found
        return
      end

      attempt = item[:attempt]
      raw_prompt = attempt["prompt"] || attempt[:prompt]
      @prompt = TokenEstimator.extract_prompt_text(raw_prompt) || ""
      raw_response = (attempt["outputs"] || attempt[:outputs])&.first
      @response = TokenEstimator.extract_output_text(raw_response) || ""
      @attempt_frame_id = "attempt-content-#{probe_result.id}-#{attempt_index}"

      render layout: false
    end

    def top_probes
      authorize @report
      # Get top 5 most vulnerable probes for this report
      probe_data = @report.probe_results
                          .includes(:probe)
                          .where("total > 0")
                          .map do |pr|
                            asr = (pr.passed.to_f / pr.total * 100).round(1)
                            {
                              name: pr.probe&.name || "Unknown",
                              asr: asr
                            }
                          end
                          .sort_by { |p| -p[:asr] }
                          .take(5)

      render json: {
        probe_names: probe_data.map { |p| p[:name] },
        asr_values: probe_data.map { |p| p[:asr] }
      }
    end

    def refresh_debug_lease
      authorize @report, :show?
      Reports::DebugWatcher.refresh_and_enqueue(@report)
      head :ok
    end

    private

    def set_report
      @report = Report.includes(:target, :scan,
                                detector_results: :detector)
                      .find(params[:id])
    end

    def set_debug_lease_report
      @report = Report.select(:id, :status, :company_id).find(params[:id])
    end

    def apply_sorting(scope)
      # Handle custom ASR sorting
      if params[:order]&.include?("asr")
        direction = params[:order].include?("desc") ? "DESC" : "ASC"

        scope.joins(Arel.sql(<<~SQL.squish))
          LEFT JOIN (
            SELECT report_id,
              SUM(passed) as passed_count,
              SUM(total) as total_count
            FROM detector_results
            GROUP BY report_id
          ) detector_totals ON reports.id = detector_totals.report_id
        SQL
        .order(Arel.sql(<<~SQL.squish))
          CASE
            WHEN COALESCE(detector_totals.total_count, 0) = 0 THEN 0
            ELSE (CAST(COALESCE(detector_totals.passed_count, 0) AS FLOAT) / detector_totals.total_count * 100)
          END #{direction}
        SQL
      elsif params.dig(:q, :s)
        # Handle ransack sorting
        scope
      else
        # Default sorting
        scope.order(created_at: :desc)
      end
    end

    # Preserve URL parameters when redirecting
    def preserve_params
      request.query_parameters.except("batch_action", "collection_selection", "ids", "authenticity_token")
    end

    def set_page_title
      @page_title = "Reports"
    end
  end
end
