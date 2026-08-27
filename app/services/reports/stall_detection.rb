# frozen_string_literal: true

module Reports
  # The reaper's four predicates, in one place.
  #
  # CheckStaleReportsJob decides when a run has stopped making progress and must be
  # retried or failed. The progress card has to answer the same question for a reader
  # -- "is this run stuck?" -- and if it derived its own answer the two would drift:
  # the card would call a run healthy that the reaper was about to interrupt, or warn
  # about one the reaper considers fine.
  #
  # Predicates only. Nothing here decides what to DO about a stalled report; that stays
  # in the job, along with the retry budget.
  module StallDetection
    HEARTBEAT_TIMEOUT = CheckStaleReportsJob::HEARTBEAT_TIMEOUT
    STARTING_TIMEOUT = CheckStaleReportsJob::STARTING_TIMEOUT

    module_function

    # Running, owned by a live process, but the heartbeat has gone quiet.
    def stale_heartbeat_scope(relation = Report.all)
      relation.running
              .where.not(heartbeat_at: nil)
              .where.not(pid: nil)
              .where(heartbeat_at: ...HEARTBEAT_TIMEOUT.ago)
    end

    # Running, but no heartbeat ever arrived: the process never got far enough to send
    # one.
    def never_started_scope(relation = Report.all)
      relation.running
              .where(heartbeat_at: nil)
              .where(updated_at: ...HEARTBEAT_TIMEOUT.ago)
    end

    # Running with no owning process. NOT necessarily stalled: this is also what a
    # finished scan looks like between the moment its process exits and the moment
    # ProcessReportJob picks it up, which is why the reaper exempts reports with a
    # queued job. Callers that want "stalled" must apply that exemption too -- see
    # `orphaned?`.
    def orphaned_scope(relation = Report.all)
      relation.running
              .where(pid: nil)
              .where.not(heartbeat_at: nil)
              .where(updated_at: ...HEARTBEAT_TIMEOUT.ago)
    end

    # Claimed for launch but never became running.
    def stuck_starting_scope(relation = Report.all)
      relation.starting.where(updated_at: ...STARTING_TIMEOUT.ago)
    end

    def stale_heartbeat?(report)
      report.running? && report.heartbeat_at.present? && report.pid.present? &&
        report.heartbeat_at < HEARTBEAT_TIMEOUT.ago
    end

    def never_started?(report)
      report.running? && report.heartbeat_at.nil? && report.updated_at < HEARTBEAT_TIMEOUT.ago
    end

    # @param awaiting_processing [Boolean] whether a ProcessReportJob is already queued
    #   for this report. A finished scan sits here with its pid cleared until that job
    #   runs, so without this it reads as an orphan -- and telling a user their finished
    #   scan is stuck is worse than saying nothing.
    def orphaned?(report, awaiting_processing: false)
      return false if awaiting_processing

      report.running? && report.pid.nil? && report.heartbeat_at.present? &&
        report.updated_at < HEARTBEAT_TIMEOUT.ago
    end

    def stuck_starting?(report)
      report.starting? && report.updated_at < STARTING_TIMEOUT.ago
    end

    # :yes / :no / :unknown -- whether a ProcessReportJob is waiting to ingest this
    # report's results.
    #
    # Three answers, because the queue lives in its own database and an unreadable one
    # is not the same as an empty one. A caller that collapsed :unknown into either
    # answer would either claim a finished scan is stuck or claim a genuinely stalled
    # one is finishing, on the strength of a failed query.
    #
    # Failed executions are excluded: a ProcessReportJob that exhausted its retries
    # keeps finished_at NULL forever, and counting it as pending would mean nothing is
    # ever going to ingest those results while we say ingestion is imminent.
    def awaiting_processing(report)
      # Savepointed on SolidQueue::Job's OWN connection, not ActiveRecord::Base's. The
      # queue has its own pool in a real deployment and shares the primary one in tests,
      # and only the model knows which -- a savepoint opened on the wrong connection
      # contains nothing, and a failed query would abort the caller's transaction
      # instead of just this read. A progress card must not be able to break the request
      # that renders it.
      queued = SolidQueue::Job.transaction(requires_new: true) do
        queued_process_job?(report)
      end

      queued ? :yes : :no
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[StallDetection] could not read the job queue: #{e.class}: #{e.message}")
      :unknown
    end

    # Batched form for a caller with many reports to judge -- the reaper walks every
    # orphan candidate, and asking per report turns one query into N transactions and
    # re-parses the whole pending set each time.
    #
    # Returns nil, not an empty set, when the queue cannot be read: an empty set means
    # "nothing is pending", and a caller must be able to tell that from "we could not
    # look".
    def awaiting_processing_report_ids
      SolidQueue::Job.transaction(requires_new: true) do
        Set.new(pending_process_job_report_ids)
      end
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[StallDetection] could not read the job queue: #{e.class}: #{e.message}")
      nil
    end

    def pending_process_job_report_ids
      SolidQueue::Job
        .where(class_name: "ProcessReportJob", finished_at: nil)
        .where.missing(:failed_execution)
        .pluck(:arguments)
        .filter_map do |args_json|
          args = args_json.is_a?(String) ? JSON.parse(args_json) : args_json
          args.dig("arguments", 0)&.to_i
        rescue JSON::ParserError
          nil
        end
    end

    def queued_process_job?(report)
      SolidQueue::Job
        .where(class_name: "ProcessReportJob", finished_at: nil)
        .where.missing(:failed_execution)
        .pluck(:arguments)
        .any? do |args_json|
          args = args_json.is_a?(String) ? JSON.parse(args_json) : args_json
          args.dig("arguments", 0)&.to_i == report.id
        rescue JSON::ParserError
          false
        end
    end

    # Any of the four. `awaiting_processing` is passed through to the one predicate it
    # applies to.
    def stalled?(report, awaiting_processing: false)
      stale_heartbeat?(report) || never_started?(report) ||
        orphaned?(report, awaiting_processing: awaiting_processing) ||
        stuck_starting?(report)
    end
  end
end
