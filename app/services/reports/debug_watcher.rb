# frozen_string_literal: true

module Reports
  module DebugWatcher
    LEASE_TTL = 45.seconds
    CACHE_PREFIX = "debug_watcher:report:"

    module_function

    def refresh(report_id)
      Rails.cache.write(cache_key(report_id), true, expires_in: LEASE_TTL)
    end

    def refresh_and_enqueue(report)
      refresh(report.id)
      BroadcastReportDebugJob.enqueue_unless_active(report.id) if report.status.in?(Report::DEBUG_STREAM_POLLING_STATUSES)
    end

    def watching?(report_id)
      Rails.cache.exist?(cache_key(report_id))
    end

    def stream_name(report)
      "report-debug:company_#{report.company_id}:report_#{report.id}"
    end

    def cache_key(report_id)
      "#{CACHE_PREFIX}#{report_id}"
    end
  end
end
