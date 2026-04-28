# Automatically retries reports that were interrupted during execution.
#
# Interruptions typically happen during:
# - Pod teardown (Kubernetes deployments, scaling, node maintenance)
# - Process crashes
# - Network partitions that cause heartbeat failures
#
# This job provides automatic recovery without user intervention, while
# respecting a stabilization delay to avoid immediate retries during
# infrastructure instability (e.g., rolling deployments).
#
# @see CheckStaleReportsJob for how reports are marked as interrupted
class RetryInterruptedReportsJob < ApplicationJob
  queue_as :default

  # Wait this long after interruption before retrying.
  # Allows pods to stabilize after deployment/scaling events.
  STABILIZATION_DELAY = 30.seconds

  def perform
    interrupted_reports = Report.interrupted
                                .where("updated_at < ?", STABILIZATION_DELAY.ago)

    count = 0
    interrupted_reports.find_each do |report|
      # Reload to get latest state (another process may have updated it)
      report.reload

      # Skip if no longer interrupted (status changed while we were processing)
      next unless report.interrupted?

      # Skip if target is not in good status
      unless report.target.status == "good"
        Rails.logger.info(
          "[RetryInterruptedReports] Skipping report #{report.id} - " \
          "target #{report.target.id} has '#{report.target.status}' status"
        )
        next
      end

      retry_interrupted_report(report)
      count += 1
    end

    Rails.logger.info("[RetryInterruptedReports] Queued #{count} interrupted reports for retry") if count > 0
  end

  private

  def retry_interrupted_report(report)
    Rails.logger.info(
      "[RetryInterruptedReports] Retrying report #{report.id} (#{report.uuid}) - " \
      "attempt #{report.retry_count + 1}/#{CheckStaleReportsJob::MAX_INTERRUPT_RETRIES}"
    )

    Report.transaction do
      report.update!(
        status: :pending,
        retry_count: report.retry_count + 1,
        last_retry_at: Time.current,
        heartbeat_at: nil, # Reset heartbeat for fresh start
        pid: nil, # Clear stale PID so new run gets a fresh process identity
        logs: append_log(
          report.logs,
          "Auto-retry #{report.retry_count + 1}: Requeued after interruption"
        )
      )
      ReportDebugLog.clear_tail_for_report(report.id)
    end
  end

  def append_log(existing_logs, message)
    timestamp = Time.current.strftime("%Y-%m-%d %H:%M:%S")
    new_entry = "[#{timestamp}] #{message}"

    if existing_logs.present?
      "#{existing_logs}\n#{new_entry}"
    else
      new_entry
    end
  end
end
