# Detects crashed/stuck scans via heartbeat timeout detection.
# Replaces PID-based health checking for multi-pod deployment support.
#
# This job checks four conditions:
# 1. Running reports with stale heartbeat_at (process crashed/hung)
# 2. Running reports that never sent a heartbeat (process never started)
# 3. Reports stuck in 'starting' status (process failed to launch)
# 4. Orphaned running reports with pid cleared but heartbeat present
#    (process died after PID-match guard cleared pid without status update)
#
# Interrupted scans (e.g., pod teardown) are marked as 'interrupted' and
# automatically retried by RetryInterruptedReportsJob. Only after exceeding
# MAX_INTERRUPT_RETRIES are they marked as permanently failed.
#
# Works across pods because it only uses database queries, not local PIDs.
#
# @see HeartbeatThread in script/db_notifier.py (sends heartbeats every 30s)
# @see RetryInterruptedReportsJob for automatic retry of interrupted scans
class CheckStaleReportsJob < ApplicationJob
  queue_as :default

  # Must be longer than heartbeat interval (30s) to allow for network delays.
  # 2 minutes = 4 missed heartbeats before considering stale.
  HEARTBEAT_TIMEOUT = 2.minutes

  # How long a report can stay in 'starting' before retry/fail.
  STARTING_TIMEOUT = 2.minutes

  # Maximum start attempts before permanent failure.
  MAX_START_RETRIES = 3

  # Maximum interrupt retries before permanent failure.
  # Uses same limit as start retries for consistency.
  MAX_INTERRUPT_RETRIES = 3

  def perform
    check_stale_running_reports
    check_never_started_running_reports
    check_orphaned_running_reports
    check_stuck_starting_reports
  end

  private

  # Detect running reports with stale heartbeat (process crashed/hung).
  # Only checks reports that have actually sent at least one heartbeat.
  # Reports with nil heartbeat are handled by check_never_started_running_reports.
  #
  # Marks as 'interrupted' for automatic retry if under MAX_INTERRUPT_RETRIES,
  # otherwise marks as permanently 'failed'.
  def check_stale_running_reports
    stale_reports = Report.running
                          .where.not(heartbeat_at: nil)
                          .where("heartbeat_at < ?", HEARTBEAT_TIMEOUT.ago)

    stale_reports.find_each do |report|
      # Reload to get latest state (another process may have updated it)
      report.reload

      # Skip if no longer running (status changed while we were processing)
      next unless report.running?

      heartbeat_age = (Time.current - report.heartbeat_at).round
      reason = "Scan stopped responding (no heartbeat for #{HEARTBEAT_TIMEOUT.inspect})"

      if report.retry_count < MAX_INTERRUPT_RETRIES
        Rails.logger.warn(
          "[CheckStaleReports] Report #{report.id} (#{report.uuid}) has stale heartbeat " \
          "(last: #{report.heartbeat_at}, age: #{heartbeat_age}s) - marking as interrupted"
        )
        mark_report_interrupted(report, reason)
      else
        Rails.logger.error(
          "[CheckStaleReports] Report #{report.id} (#{report.uuid}) has stale heartbeat " \
          "(last: #{report.heartbeat_at}, age: #{heartbeat_age}s) - " \
          "exceeded #{MAX_INTERRUPT_RETRIES} retries, marking as failed"
        )
        mark_report_failed(report, "#{reason} (after #{MAX_INTERRUPT_RETRIES} retry attempts)")
      end
    end
  end

  # Detect running reports that never sent a heartbeat (process never started).
  # This catches reports that transitioned to 'running' but the Python process
  # crashed or failed before sending the first heartbeat.
  #
  # Marks as 'interrupted' for automatic retry if under MAX_INTERRUPT_RETRIES,
  # otherwise marks as permanently 'failed'.
  def check_never_started_running_reports
    zombie_reports = Report.running
                           .where(heartbeat_at: nil)
                           .where("updated_at < ?", HEARTBEAT_TIMEOUT.ago)

    zombie_reports.find_each do |report|
      report.reload

      # Skip if no longer running or heartbeat arrived while processing
      next unless report.running?
      next if report.heartbeat_at.present?

      age = (Time.current - report.updated_at).round
      reason = "Scan process never started (no heartbeat received after #{HEARTBEAT_TIMEOUT.inspect})"

      if report.retry_count < MAX_INTERRUPT_RETRIES
        Rails.logger.warn(
          "[CheckStaleReports] Report #{report.id} (#{report.uuid}) is running " \
          "but never sent heartbeat (age: #{age}s) - marking as interrupted"
        )
        mark_report_interrupted(report, reason)
      else
        Rails.logger.error(
          "[CheckStaleReports] Report #{report.id} (#{report.uuid}) is running " \
          "but never sent heartbeat (age: #{age}s) - " \
          "exceeded #{MAX_INTERRUPT_RETRIES} retries, marking as failed"
        )
        mark_report_failed(report, "#{reason} (after #{MAX_INTERRUPT_RETRIES} retry attempts)")
      end
    end
  end

  # Detect orphaned running reports where the PID was cleared but the report
  # was never transitioned out of 'running'. This happens when a child process
  # triggers notify_report_stopped but the PID-match guard prevents the status
  # update (only clears pid), leaving the report running with no owning process.
  #
  # Conditions: running + pid=nil + heartbeat present + updated_at stale.
  # The heartbeat distinguishes from never-started (handled separately).
  # The updated_at check provides a safety window against race conditions.
  def check_orphaned_running_reports
    orphaned_reports = Report.running
                             .where(pid: nil)
                             .where.not(heartbeat_at: nil)
                             .where("updated_at < ?", HEARTBEAT_TIMEOUT.ago)

    orphaned_reports.find_each do |report|
      report.reload

      next unless report.running?
      next unless report.pid.nil?
      next if report.heartbeat_at.nil?

      reason = "Scan process orphaned (running with no owning process — pid cleared but status not updated)"

      if report.retry_count < MAX_INTERRUPT_RETRIES
        Rails.logger.warn(
          "[CheckStaleReports] Report #{report.id} (#{report.uuid}) is orphaned " \
          "(running, pid=nil, heartbeat present) - marking as interrupted"
        )
        mark_report_interrupted(report, reason)
      else
        Rails.logger.error(
          "[CheckStaleReports] Report #{report.id} (#{report.uuid}) is orphaned " \
          "(running, pid=nil, heartbeat present) - " \
          "exceeded #{MAX_INTERRUPT_RETRIES} retries, marking as failed"
        )
        mark_report_failed(report, "#{reason} (after #{MAX_INTERRUPT_RETRIES} retry attempts)")
      end
    end
  end

  # Detect reports stuck in 'starting' status (process never started).
  # Retries up to MAX_START_RETRIES times with exponential backoff.
  def check_stuck_starting_reports
    stuck_reports = Report.starting
                          .where("updated_at < ?", STARTING_TIMEOUT.ago)

    stuck_reports.find_each do |report|
      # Reload to get latest state
      report.reload

      # Skip if no longer starting
      next unless report.starting?

      if report.retry_count < MAX_START_RETRIES
        retry_report(report)
      else
        mark_report_failed(
          report,
          "Failed after #{MAX_START_RETRIES} start attempts. " \
          "Each attempt timed out after #{STARTING_TIMEOUT.inspect}."
        )
      end
    end
  end

  def retry_report(report)
    Rails.logger.warn(
      "[CheckStaleReports] Report #{report.id} stuck in starting - " \
      "moving to pending for retry (attempt #{report.retry_count + 1}/#{MAX_START_RETRIES})"
    )

    report.update!(
      status: :pending,
      retry_count: report.retry_count + 1,
      last_retry_at: Time.current,
      logs: append_log(
        report.logs,
        "Retry #{report.retry_count + 1}: Previous start attempt timed out after #{STARTING_TIMEOUT.inspect}"
      )
    )
  end

  # Mark report as interrupted for automatic retry by RetryInterruptedReportsJob.
  # The report will be retried after a stabilization delay to allow pods to settle.
  def mark_report_interrupted(report, reason)
    Rails.logger.warn(
      "[CheckStaleReports] Marking report #{report.id} as interrupted " \
      "(retry #{report.retry_count + 1}/#{MAX_INTERRUPT_RETRIES}): #{reason}"
    )

    report.update!(
      status: :interrupted,
      logs: append_log(report.logs, "Interrupted: #{reason}")
    )
  end

  def mark_report_failed(report, reason)
    Rails.logger.error("[CheckStaleReports] Marking report #{report.id} as failed: #{reason}")

    report.update!(
      status: :failed,
      logs: append_log(report.logs, reason)
    )
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
