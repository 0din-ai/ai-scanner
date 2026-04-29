# frozen_string_literal: true

class BroadcastReportDebugJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(report_id, *_, **_) { "broadcast_report_debug:#{report_id}" }, on_conflict: :block

  POLL_INTERVAL = 10.seconds
  POLLER_LEASE_TTL = 35.seconds
  CACHE_PREFIX = "broadcast_report_debug:"
  # SIGTERM-driven terminal transitions: Python's HeartbeatThread (script/db_notifier.py) takes
  # up to ~30s to detect the new status, then SIGTERM triggers JournalSyncThread.stop() which
  # writes one final tail to report_debug_logs. The delay below must exceed
  # HeartbeatThread::DEFAULT_INTERVAL (30s) + JournalSyncThread join (5s) + DB write headroom.
  # If either Python-side timing constant changes, revisit this delay.
  FINAL_TAIL_FOLLOWUP_STATUSES = %w[stopped failed interrupted].freeze
  FINAL_TAIL_FOLLOWUP_DELAY = 60.seconds
  FINAL_TAIL_FOLLOWUP_TTL = 12.hours

  def self.enqueue_unless_active(report_id)
    return false unless Rails.cache.write(poller_cache_key(report_id), true, expires_in: POLLER_LEASE_TTL, unless_exist: true)

    perform_later(report_id)
    true
  end

  def self.enqueue_status_change(report_id, status)
    return enqueue_unless_active(report_id) if status.to_s.in?(Report::DEBUG_STREAM_POLLING_STATUSES)

    mark_poller_active(report_id)
    perform_later(report_id)
    schedule_final_tail_followup(report_id) if status.to_s.in?(FINAL_TAIL_FOLLOWUP_STATUSES)
    true
  end

  def self.schedule_final_tail_followup(report_id, report: nil)
    # We intentionally read the report outside any tenant scope here:
    # only `updated_at` and `status` are touched (both unencrypted columns) and
    # this method may be called from contexts that have not yet established a
    # tenant (e.g., scheduling code paths). All downstream broadcast work that
    # touches encrypted attributes is wrapped in `ActsAsTenant.with_tenant(report.company)`.
    report ||= ActsAsTenant.without_tenant { Report.find_by(id: report_id) }
    return false unless report.present?

    generation = final_tail_followup_generation(report)
    return false unless Rails.cache.write(
      final_tail_followup_cache_key(report_id, generation),
      true,
      expires_in: FINAL_TAIL_FOLLOWUP_TTL,
      unless_exist: true
    )

    set(wait: FINAL_TAIL_FOLLOWUP_DELAY).perform_later(report_id, final_tail_followup: true, final_tail_followup_generation: generation)
    true
  end

  # Generation token used to dedupe final-tail follow-up jobs via Rails.cache.
  # Status is included so transitions through different terminal statuses
  # (e.g. stopped -> failed) cannot suppress each other when updated_at
  # resolves to the same micro-second bucket.
  def self.final_tail_followup_generation(report)
    timestamp = report.updated_at&.to_f || 0
    status = report.status.to_s
    "#{status}:#{timestamp}"
  end

  def self.mark_poller_active(report_id)
    Rails.cache.write(poller_cache_key(report_id), true, expires_in: POLLER_LEASE_TTL)
  end

  def self.clear_poller(report_id)
    Rails.cache.delete(poller_cache_key(report_id))
    Rails.cache.delete(digest_cache_key(report_id))
    Rails.cache.delete(fingerprint_cache_key(report_id))
  end

  def self.clear_final_tail_followup(report_id, generation: nil)
    return false if generation.blank?

    Rails.cache.delete(final_tail_followup_cache_key(report_id, generation))
  end

  def self.poller_cache_key(report_id)
    "#{CACHE_PREFIX}poller:#{report_id}"
  end

  def self.digest_cache_key(report_id)
    "#{CACHE_PREFIX}digest:#{report_id}"
  end

  def self.fingerprint_cache_key(report_id)
    "#{CACHE_PREFIX}fingerprint:#{report_id}"
  end

  def self.final_tail_followup_cache_key(report_id, generation)
    "#{CACHE_PREFIX}final_tail_followup:#{report_id}:#{generation}"
  end

  def perform(report_id, final_tail_followup: false, final_tail_followup_generation: nil)
    self.class.mark_poller_active(report_id) unless final_tail_followup

    unless Reports::DebugWatcher.watching?(report_id)
      clear_job_state(report_id, final_tail_followup: final_tail_followup, final_tail_followup_generation: final_tail_followup_generation)
      return
    end

    report = ActsAsTenant.without_tenant { Report.find_by(id: report_id) }
    if report.nil?
      clear_job_state(report_id, final_tail_followup: final_tail_followup, final_tail_followup_generation: final_tail_followup_generation)
      return
    end

    errored = false
    report_gone = false
    reenqueued = false
    observed_polling = false

    begin
      ActsAsTenant.with_tenant(report.company) do
        if reload_report(report)
          observed_polling = polling_report?(report)
          if should_broadcast?(report, final_tail_followup: final_tail_followup, final_tail_followup_generation: final_tail_followup_generation)
            fingerprint = Reports::DebugStreamFingerprint.new(report).call
            build_and_broadcast(report, fingerprint) unless fingerprint_unchanged?(report_id, fingerprint)
          end
        else
          report_gone = true
        end
      end
    rescue StandardError => e
      errored = true
      Rails.logger.error("[BroadcastReportDebugJob] report=#{report_id}: #{e.class} - #{e.message}")
      raise
    ensure
      unless errored
        if final_tail_followup
          self.class.clear_final_tail_followup(report_id, generation: final_tail_followup_generation)
        else
          reenqueued = reenqueue_if_watching_polling(report_id, observed_polling: observed_polling) unless report_gone
          self.class.clear_poller(report_id) unless reenqueued
        end
      end
    end
  end

  private

  def clear_job_state(report_id, final_tail_followup:, final_tail_followup_generation: nil)
    self.class.clear_poller(report_id)
    return unless final_tail_followup

    self.class.clear_final_tail_followup(report_id, generation: final_tail_followup_generation)
  end

  def reload_report(report)
    report.reload
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def polling_report?(report)
    report.status.in?(Report::DEBUG_STREAM_POLLING_STATUSES)
  end

  def reenqueue_if_watching_polling(report_id, observed_polling: false)
    return false unless Reports::DebugWatcher.watching?(report_id)

    report = ActsAsTenant.without_tenant { Report.find_by(id: report_id) }
    return false unless report.present?

    reenqueued = false
    if polling_report?(report)
      reenqueue(report_id)
      reenqueued = true
    end

    self.class.schedule_final_tail_followup(report_id, report: report) if observed_polling && terminal_tail_status?(report)
    reenqueued
  end

  def terminal_tail_status?(report)
    !polling_report?(report) && report.status.in?(FINAL_TAIL_FOLLOWUP_STATUSES)
  end

  def should_broadcast?(report, final_tail_followup:, final_tail_followup_generation: nil)
    return true unless final_tail_followup

    terminal_tail_status?(report) && self.class.final_tail_followup_generation(report) == final_tail_followup_generation
  end

  def reenqueue(report_id)
    self.class.mark_poller_active(report_id)
    self.class.set(wait: POLL_INTERVAL).perform_later(report_id)
  end

  def fingerprint_unchanged?(report_id, fingerprint)
    return false if fingerprint.blank?

    Rails.cache.read(self.class.fingerprint_cache_key(report_id)) == fingerprint[:digest]
  end

  def build_and_broadcast(report, fingerprint)
    payload = Reports::DebugStreamPayload.new(report).call
    current_digest = broadcast_digest(report, payload)
    last_digest = Rails.cache.read(self.class.digest_cache_key(report.id))

    if current_digest != last_digest
      broadcast_debug_stream(report, payload)
      broadcast_activity_summary(report, payload)
      Rails.cache.write(self.class.digest_cache_key(report.id), current_digest, expires_in: 5.minutes)
    end

    cache_fingerprint(report, fingerprint)
  end

  def cache_fingerprint(report, fingerprint)
    return if fingerprint.blank?

    Rails.cache.write(self.class.fingerprint_cache_key(report.id), fingerprint[:digest], expires_in: 5.minutes)
  end

  def broadcast_digest(report, payload)
    activity = payload[:activity] || {}
    log_metadata = payload[:log_metadata] || {}

    Digest::MD5.hexdigest({
      payload_digest: payload[:digest],
      report_status: report.status,
      activity_active: activity[:active],
      activity_status_label: activity[:status_label],
      activity_entry_count: activity[:entry_count],
      activity_log_line_count: activity[:log_line_count],
      activity_updated_at: digest_timestamp(activity[:updated_at]),
      log_source: log_metadata[:source],
      log_offset: log_metadata[:offset],
      log_synced_at: digest_timestamp(log_metadata[:synced_at]),
      log_truncated: log_metadata[:truncated],
      log_digest: log_metadata[:digest]
    }.to_json)
  end

  def digest_timestamp(value)
    return nil if value.blank?
    return value.iso8601(6) if value.respond_to?(:iso8601)

    value.to_s
  end

  def broadcast_debug_stream(report, payload)
    Turbo::StreamsChannel.broadcast_replace_to(
      Reports::DebugWatcher.stream_name(report),
      target: "report-debug-stream-content",
      partial: "admin/reports/debug_panel_stream",
      locals: { report: report, payload: payload }
    )
  end

  def broadcast_activity_summary(report, payload)
    Turbo::StreamsChannel.broadcast_replace_to(
      Reports::DebugWatcher.stream_name(report),
      target: "report-activity-stream-summary",
      partial: "admin/reports/activity_stream_summary",
      locals: { report: report, payload: payload }
    )
  end
end
