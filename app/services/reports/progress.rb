# frozen_string_literal: true

module Reports
  # What to tell a reader about a run that has not finished.
  #
  # A running report's page used to render the same four figures a finished one does --
  # Duration N/A, ASR N/A, 0 / 0 attacks, 0 vulnerabilities -- in the same layout, so a
  # scan still in flight read as one that had completed and found nothing. Those are not
  # partial results; they are the absence of any, because probe_results is not written
  # until the journal is ingested at the end.
  #
  # Three separate questions, deliberately not collapsed into one status:
  #
  #   PHASE           where the run is in its lifecycle
  #   OWNERSHIP       whether a scanner process still holds this report
  #   FEED FRESHNESS  whether what we know is current
  #
  # A run can be running and unowned (its process exited, the results are queued for
  # ingest), or owned and silent (alive but not reporting). Collapsing those would make
  # one of them a lie.
  class Progress
    # How recently the journal must have changed for the feed to count as live. Longer
    # than a poll interval, because a probe can legitimately take a while to produce its
    # next line.
    FEED_FRESH_WINDOW = 60.seconds

    # Bump when the shape of the rendered representation changes, so a cached response
    # from the previous shape cannot be served after a deploy.
    REPRESENTATION_VERSION = 1

    PHASE_LABELS = {
      queued: "Queued",
      starting: "Starting",
      running: "Running",
      stalled: "Not responding",
      interrupted: "Interrupted, will retry",
      finalizing: "Recording results",
      unknown: "Status unavailable",
      finished: "Finished"
    }.freeze

    # Phases where the page should keep asking. `finished` is absent on purpose: there
    # is nothing further to learn.
    # `unknown` polls too: not knowing is a reason to ask again, not to stop.
    POLLING_PHASES = %i[queued starting running stalled interrupted finalizing unknown].freeze

    def initialize(report, now: Time.current)
      @report = report
      @now = now
    end

    attr_reader :report, :now

    def phase
      @phase ||= derive_phase
    end

    def phase_label
      PHASE_LABELS.fetch(phase, PHASE_LABELS[:running])
    end

    def poll?
      POLLING_PHASES.include?(phase)
    end

    def in_flight?
      phase != :finished
    end

    def stalled?
      phase == :stalled
    end

    # Named for what was observed, never for a cause we cannot see. We do not know that
    # a process died; we know no heartbeat arrived.
    def stall_reason
      return nil unless stalled?

      if StallDetection.stuck_starting?(report)
        "This scan was claimed for launch but never started running."
      elsif StallDetection.never_started?(report)
        "This scan started but never reported any activity."
      elsif StallDetection.stale_heartbeat?(report)
        "This scan has stopped reporting activity."
      else
        "This scan is no longer held by a scanner process."
      end
    end

    # :yes / :no / :unknown. A finished scan sits `running` with its pid cleared until
    # ProcessReportJob runs, so ownership rather than the clock decides between
    # `finalizing` and `stalled` -- and when the queue cannot be read, neither answer is
    # earned.
    def awaiting_processing
      @awaiting_processing ||= StallDetection.awaiting_processing(report)
    end

    # A variant child executes mapped threat variants and its recorded plan counts
    # variants, so calling them probes would misstate what is being measured -- the same
    # distinction Report#processed_scope_summary makes.
    def unit
      report.is_variant_report? ? "variant" : "probe"
    end

    def completed_units
      journal.completed_count
    end

    # The plan recorded at launch. Nil for a report launched before that was recorded,
    # which is exactly when we must not state a ratio.
    def total_units
      recorded = report.planned_probe_count
      recorded if recorded.present? && recorded.positive?
    end

    # A ratio is only stated when both halves are real. Anything else shows completed
    # work alone, rather than inventing a denominator.
    def determinate?
      total_units.present? && journal.present?
    end

    def percent_complete
      return nil unless determinate?

      # Capped: a resumed run can re-evaluate a probe the plan did not anticipate, and
      # "7 of 5" reads as a bug rather than as progress.
      [ (completed_units.to_f / total_units * 100).round, 100 ].min
    end

    def last_completed_probe
      journal.last_completed_probe
    end

    # garak's own start, from the journal. reports.start_time is not written until the
    # journal is ingested, so during a run this is the only source.
    def started_at
      journal.started_at || report.created_at
    end

    def elapsed_seconds
      return nil if started_at.nil?

      (now - started_at).round
    end

    # Exactly what the card shows, so the representation key and the rendered text
    # cannot disagree about when they change.
    def elapsed_label
      return nil if elapsed_seconds.nil?

      ActionController::Base.helpers.distance_of_time_in_words(elapsed_seconds)
    end

    def last_contact_at
      [ report.heartbeat_at, journal_updated_at ].compact.max
    end

    # fresh / stale / unknown -- three answers, because "we have never heard anything"
    # is not the same as "we heard something and it was a while ago".
    def feed_state
      contact = last_contact_at
      return :unknown if contact.nil?

      contact >= FEED_FRESH_WINDOW.ago(now) ? :fresh : :stale
    end

    def retry_attempt
      report.retry_count
    end

    # Everything the rendered card is derived from. The endpoint is conditional on THIS
    # rather than on updated_at, so a transition driven only by the clock -- a run
    # crossing the stall threshold with no database write -- still re-renders, and an
    # unchanged representation can skip the journal read entirely.
    def representation_key
      Digest::SHA256.hexdigest(
        [
          REPRESENTATION_VERSION,
          report.id,
          report.status,
          phase,
          completed_units,
          total_units,
          feed_state,
          retry_attempt,
          started_at&.to_i,
          determinate?,
          journal.present?,
          last_completed_probe,
          stall_reason,
          unit,
          # The rendered elapsed STRING, not a bucket approximating it.
          #
          # A key that changed every five seconds would make every poll a 200 carrying
          # an identical card, turning the conditional response off while looking like
          # it works. But a plain per-minute bucket is wrong in the other direction:
          # distance_of_time_in_words rounds at 30, 90, 150 seconds, so 89s renders
          # "1 minute" and 90s renders "2 minutes" while sharing bucket 1 -- a 304
          # carrying text the card has outgrown. Keying what is displayed cannot drift
          # from what is displayed.
          elapsed_label
        ].join("|")
      )
    end

    def as_json
      {
        phase: phase,
        phase_label: phase_label,
        poll: poll?,
        stalled: stalled?,
        stall_reason: stall_reason,
        unit: unit,
        completed_units: completed_units,
        total_units: total_units,
        determinate: determinate?,
        percent_complete: percent_complete,
        last_completed_probe: last_completed_probe,
        started_at: started_at&.iso8601,
        elapsed_seconds: elapsed_seconds,
        feed_state: feed_state,
        retry_attempt: retry_attempt
      }
    end

    private

    def derive_phase
      return :finished if terminal_status?

      case report.status
      when "pending"
        :queued
      when "interrupted"
        :interrupted
      when "processing"
        :finalizing
      when "starting"
        StallDetection.stuck_starting?(report) ? :stalled : :starting
      when "running"
        running_phase
      else
        :running
      end
    end

    def running_phase
      # Ownership first, and ONLY for a report that is orphan-shaped. A run whose
      # process has exited with results queued for ingest is finalizing, however long
      # ago its last heartbeat was -- but a run that still holds a pid is neither, and
      # asking the queue about it would be a query per poll for nothing.
      if report.pid.nil?
        case awaiting_processing
        when :yes then return :finalizing
        when :unknown
          # An orphan-shaped report with an unreadable queue could be either finishing
          # or genuinely stalled, and a fresh launch is neither. Saying so is better
          # than picking one: guessing `finalizing` would hide a real stall behind a
          # reassuring label, and guessing `stalled` would raise a false alarm from a
          # failed query.
          return :unknown if StallDetection.orphaned?(report)
        end

        return :stalled if StallDetection.orphaned?(report)
      end

      return :stalled if StallDetection.stale_heartbeat?(report) || StallDetection.never_started?(report)

      :running
    end

    # `stopped` is terminal here: Reports::Stop writes it immediately and the scanner
    # process self-terminates on its next heartbeat, so there is no intermediate
    # cancelling state to model. Inventing one would describe a lifecycle this app does
    # not have.
    def terminal_status?
      %w[completed failed stopped].include?(report.status)
    end

    def journal
      @journal ||= JournalSummary.for(report, journal_updated_at: journal_updated_at)
    end

    def journal_updated_at
      unless defined?(@journal_updated_at)
        @journal_updated_at = RawReportData.where(report_id: report.id).pick(:updated_at)
      end

      @journal_updated_at
    end
  end
end
