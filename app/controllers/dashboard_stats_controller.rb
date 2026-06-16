class DashboardStatsController < ApplicationController
  def total_scans_data
    days = params[:days].present? && params[:days].to_i > 0 ? params[:days].to_i : 1
    result = Stats::TotalScansData.new(days: days).call
    render json: result
  end

  def avg_asr_score
    days = params[:days].present? && params[:days].to_i > 0 ? params[:days].to_i : 7
    result = Stats::AverageAsrScore.call(days: days)
    render json: result
  end

  def avg_scan_time_data
    days = params[:days].to_i
    days = 7 if days <= 0 || !params[:days].present?
    result = Stats::AvgScanTimeData.new(days: days).call

    render json: result
  end

  def probes_data
    days = params[:days].to_i
    days = 30 if days <= 0 || !params[:days].present?
    result = Stats::ProbesData.new(days: days).call
    render json: result
  end

  def targets_timeline_data
    result = Stats::TargetsTimelineData.new.call
    render json: result
  end

  def vulnerable_targets_over_time
    days = params[:days].to_i
    days = 30 if days <= 0 || !params[:days].present?
    result = Stats::VulnerableTargetsOverTime.new(days: days).call
    render json: result
  end

  def reports_timeline_data
    result = Stats::ReportsTimelineData.new(
      target_id: params[:target_id],
      scan_id: params[:scan_id]
    ).call
    render json: result
  end

  def probes_passed_failed_timeline_data
    result = Stats::ProbesPassedFailedTimelineData.new(target_id: params[:target_id]).call
    render json: result
  end

  def probe_results_timeline_data
    result = Stats::ProbeResultsTimelineData.new(probe_id: params[:probe_id]).call
    render json: result
  end

  def probe_success_rate_data
    result = Stats::ProbeSuccessRateData.new(
      probe_id: params[:probe_id],
      target_id: params[:target_id],
      scan_id: params[:scan_id],
      report_id: params[:report_id]
    ).call
    render json: result
  end

  def detector_activity_data
    result = Stats::DetectorActivityData.new(
      target_id: params[:target_id],
      scan_id: params[:scan_id],
      report_id: params[:report_id]
    ).call
    render json: result
  end

  def attack_fails_by_target_data
    result = Stats::AttackFailsByTargetData.new(scan_id: params[:scan_id]).call
    render json: result
  end

  def taxonomy_distribution_data
    result = Stats::TaxonomyDistributionData.new.call
    render json: result
  end

  def probe_disclosure_stats
    result = Stats::ProbeDisclosureStats.new.call
    render json: result
  end

  def scan_and_target_counts_over_time
    days = params[:days].to_i
    days = 7 if days <= 0
    result = Stats::ScanAndTargetCountsOverTime.call(days: days)
    render json: result
  end
end
