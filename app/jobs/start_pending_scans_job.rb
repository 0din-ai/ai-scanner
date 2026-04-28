# frozen_string_literal: true

# Job responsible for starting pending scans with atomic claiming.
# Prevents race conditions in multi-pod deployments where multiple pods
# could try to start the same scan simultaneously.
#
# Uses atomic UPDATE...WHERE status=pending pattern to ensure only one
# pod wins the claim for each pending report.
class StartPendingScansJob < ApplicationJob
  queue_as :default

  def perform
    # 1. Process priority scans first (bypass slot limits)
    process_priority_scans

    # 2. Process standard scans (respect slot limits)
    available_slots = calculate_available_slots
    return if available_slots <= 0

    Rails.logger.info("[StartPendingScans] #{available_slots} slots available, looking for pending scans")

    eligible_reports(available_slots).each do |report|
      start_scan_if_claimable(report)
    end
  end

  private

  def process_priority_scans
    # Find all pending reports that belong to priority scans
    priority_reports = Report.pending
                             .joins(:scan)
                             .where(scans: { priority: true })
                             .where(eligible_for_start_conditions)
                             .includes(:target)

    return if priority_reports.empty?

    Rails.logger.info("[StartPendingScans] Found #{priority_reports.count} priority reports, starting immediately")

    priority_reports.each do |report|
      start_scan_if_claimable(report)
    end
  end

  def calculate_available_slots
    running_count = Report.active.count
    limit = SettingsService.parallel_scans_limit
    available = limit - running_count

    Rails.logger.info(
      "[StartPendingScans] Running: #{running_count}, Limit: #{limit}, Available: #{available}"
    )

    available
  end

  # Find pending reports eligible for starting (respects exponential backoff)
  # Uses SQL for efficient filtering instead of loading all into Ruby
  #
  # Priority order:
  # 1. Retried reports first (interrupted scans that were requeued)
  # 2. Then by creation time (FIFO for equal retry counts)
  def eligible_reports(limit)
    Report.pending
          .joins(:scan)
          .where(scans: { priority: false }) # Only select standard scans here
          .where(eligible_for_start_conditions)
          .includes(:target, :company) # Eager load for target.status and rate limit checks
          .order(retry_count: :desc, created_at: :asc)
          .limit(limit)
  end

  # SQL conditions for exponential backoff:
  # - Never retried (last_retry_at IS NULL), OR
  # - Backoff period has elapsed: last_retry_at < NOW() - (2^retry_count minutes)
  def eligible_for_start_conditions
    <<~SQL.squish
      last_retry_at IS NULL OR
      last_retry_at < NOW() - (POWER(2, COALESCE(retry_count, 0)) * INTERVAL '1 minute')
    SQL
  end

  def start_scan_if_claimable(report)
    company = report.company

    # Check company rate limit before attempting claim
    unless company.scan_allowed?
      Rails.logger.info(
        "[StartPendingScans] Report #{report.id} skipped - company #{company.id} at scan limit (#{company.scans_remaining} remaining)"
      )
      return
    end

    # Attempt atomic claim - only one pod can succeed
    if claim_for_starting(report)
      # Increment counter only after successful claim (failed/cancelled scans don't count)
      company.increment_scan_count!
      Rails.logger.info("[StartPendingScans] Claimed report #{report.id}, starting scan")
      report.reload

      # Record queue wait metric since update_all bypassed callbacks
      record_queue_wait_metric_for_report(report) if MonitoringService.active?

      # RunGarakScan handles invalid target status by marking report as failed
      # with appropriate error messaging (see handle_invalid_target_status)
      ActsAsTenant.with_tenant(company) do
        Scanner.run_hooks(:before_scan_start, { report: report, company: company })
        RunGarakScan.new(report).call
      end
    else
      Rails.logger.debug("[StartPendingScans] Report #{report.id} already claimed by another process")
    end
  end

  # Atomic claim: UPDATE only succeeds if report is still pending
  def claim_for_starting(report)
    updated_count = 0
    Report.transaction do
      updated_count = Report.where(id: report.id, status: :pending)
                            .update_all(status: :starting, updated_at: Time.current)
      ReportDebugLog.clear_tail_for_report(report.id) if updated_count.positive?
    end
    claimed = updated_count.positive?

    # Broadcast immediately since update_all bypasses callbacks
    # Pass company_id for company-scoped broadcast
    BroadcastRunningStatsJob.perform_later(report.company_id) if claimed

    claimed
  end

  # Record queue wait metric manually since update_all bypasses callbacks
  def record_queue_wait_metric_for_report(report)
    wait_time = (report.updated_at - report.created_at).to_i

    Rails.logger.info("[Monitoring Metrics] Recording queue_wait_seconds = #{wait_time} for report #{report.uuid}")

    MonitoringService.transaction("start_pending_scan", "background") do
      # Build all labels and set them in one batch for better performance
      labels = {
        report_uuid: report.uuid,
        scan_name: report.scan.name,
        target_name: report.target.name,
        target_model: report.target.model,
        scan_id: report.scan.id,
        trace_id: MonitoringService.current_trace_id || "none",
        queue_wait_seconds: wait_time
      }

      MonitoringService.set_labels(labels)

      Rails.logger.info("[Monitoring Metrics] Labels set: queue_wait_seconds=#{wait_time}")
    end
  end
end
