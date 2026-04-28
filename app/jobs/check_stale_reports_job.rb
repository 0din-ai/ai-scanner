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
  # Only checks reports that have actually sent at least one heartbeat and
  # still have a PID set (active process owner). Reports with nil PID are
  # handled by check_orphaned_running_reports instead.
  #
  # Marks as 'interrupted' for automatic retry if under MAX_INTERRUPT_RETRIES,
  # otherwise marks as permanently 'failed'.
  def check_stale_running_reports
    stale_reports = Report.running
                          .where.not(heartbeat_at: nil)
                          .where.not(pid: nil)
                          .where("heartbeat_at < ?", HEARTBEAT_TIMEOUT.ago)

    stale_reports.find_each do |report|
      # Reload to get latest state (another process may have updated it)
      report.reload

      # Skip if no longer running (status changed while we were processing)
      next unless report.running?
      # Skip if PID was cleared (now handled by check_orphaned_running_reports)
      next if report.pid.nil?
      # Skip if heartbeat arrived since the query ran
      next if report.heartbeat_at.nil? || report.heartbeat_at > HEARTBEAT_TIMEOUT.ago

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
  # was never transitioned out of 'running'. This can happen when the parent
  # process receives SIGTERM — notify_report_stopped clears the PID (since it
  # matches), but the process exits before a terminal status is set.
  #
  # Defence-in-depth: the signal handler fix (os._exit in children) and PID-match
  # guard prevent most orphan scenarios, but OOM kills or unexpected crashes
  # between PID-clear and status-update can still leave this state.
  #
  # Note: raw_report_data may exist for orphaned reports because JournalSyncThread
  # writes incrementally during the scan. Its presence does NOT mean the scan
  # completed — it may contain partial data. OrphanRawReportDataJob handles
  # recovery of raw_report_data after the report reaches a terminal state.
  #
  # Additionally, a report in this state may be a completed scan awaiting async
  # processing — the scan finished, ProcessReportJob was enqueued, PID was cleared,
  # but ProcessReportJob hasn't run yet. To avoid interrupting these reports, we
  # skip any that have a pending ProcessReportJob in Solid Queue.
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
      # Re-check updated_at safety window after reload
      next if report.updated_at > HEARTBEAT_TIMEOUT.ago

      # Skip reports with a pending ProcessReportJob — these are completed scans
      # awaiting async processing, not true orphans. This prevents interrupting
      # reports during normal queue backlog between scan completion and processing.
      if pending_process_job_report_ids.include?(report.id)
        Rails.logger.info(
          "[CheckStaleReports] Report #{report.id} (#{report.uuid}) has pending ProcessReportJob - " \
          "skipping orphan detection (scan completed, awaiting processing)"
        )
        next
      end

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

    Report.transaction do
      report.update!(
        status: :pending,
        retry_count: report.retry_count + 1,
        last_retry_at: Time.current,
        logs: append_log(
          report.logs,
          "Retry #{report.retry_count + 1}: Previous start attempt timed out after #{STARTING_TIMEOUT.inspect}"
        )
      )
      ReportDebugLog.clear_tail_for_report(report.id)
    end
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
      logs: append_log(logs_with_live_tail(report), "Interrupted: #{reason}")
    )
  end

  def mark_report_failed(report, reason)
    Rails.logger.error("[CheckStaleReports] Marking report #{report.id} as failed: #{reason}")

    report.update!(
      status: :failed,
      logs: append_log(logs_with_live_tail(report), reason)
    )
  end

  def logs_with_live_tail(report)
    logs = report.logs
    tail = current_live_tail(report)

    return logs if tail.blank?
    return tail if logs.blank?
    return logs if logs_end_with_tail?(logs, tail)

    "#{logs}\n#{tail}"
  end

  def logs_end_with_tail?(logs, tail)
    logs.to_s.rstrip.end_with?(tail.to_s.rstrip)
  end

  def current_live_tail(report)
    return nil unless report.running?

    report.report_debug_log&.tail
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

  # Report IDs that have a pending ProcessReportJob in Solid Queue.
  # Used to distinguish completed scans awaiting processing from true orphans.
  # Memoized per perform cycle to avoid repeated queries.
  def pending_process_job_report_ids
    @pending_process_job_report_ids ||= begin
      pending_jobs = SolidQueue::Job
        .where(class_name: "ProcessReportJob")
        .where(finished_at: nil)
        .pluck(:arguments)

      report_ids = pending_jobs.filter_map do |args_json|
        args = args_json.is_a?(String) ? JSON.parse(args_json) : args_json
        args.dig("arguments", 0)&.to_i
      rescue JSON::ParserError
        nil
      end

      Set.new(report_ids)
    end
  end
end
