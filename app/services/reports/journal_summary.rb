# frozen_string_literal: true

module Reports
  # What a run has actually finished, read from the journal garak is still writing.
  #
  # This is the ONE definition of "completed probe" while a scan is in flight.
  # Resumption already had one -- RunGarakScan skips probes that produced a valid eval
  # row -- and a progress figure that counted differently would tell a user a probe was
  # done that the next attempt then re-ran, or the reverse. RunGarakScan now calls this,
  # so there is a single answer.
  #
  # A probe is complete when it has at least one eval row GarakEvalRowValidator accepts
  # with a probe and detector present. garak emits one eval per DETECTOR, so counting
  # rows would multiply a probe by its detector count; the unit is the distinct probe
  # classname. Rows with a zero total, a missing probe or detector, or impossible counts
  # are not completed work -- they are exactly what the resume path retries.
  #
  # ## Why the journal is read through SQL
  #
  # jsonl_data holds every attempt with its full prompts and outputs, so a long run's
  # column is large. Loading it into Ruby on every poll would allocate all of it per
  # viewer per cycle, so Postgres splits the journal into lines and returns only the
  # candidates.
  #
  # The filter is a strict SUPERSET of the lines that matter: every real eval or init row
  # carries `entry_type` at the top level, so it must contain the marker. It cannot be
  # forged from prompt or output text, because JSON escapes an inner quote as \" -- a
  # prompt containing the literal marker does not match. Nested objects (an attempt's
  # `notes`) can match, which costs one extra line of transfer and nothing else: every
  # candidate is still parsed and re-validated in Ruby.
  class JournalSummary
    # Bump when the shape of the cached payload changes, so a deploy cannot read a stale
    # entry written by the previous shape.
    CACHE_VERSION = 1
    CACHE_TTL = 1.hour

    # Anchored on nothing deliberately: `entry_type` is not guaranteed to be the first
    # key, and garak writes with Python's json.dumps (`"key": "value"`) while specs build
    # fixtures with Ruby's to_json (`"key":"value"`). Both, and tabs, match.
    CANDIDATE_LINE_PATTERN = '"entry_type"[[:space:]]*:[[:space:]]*"(eval|init)"'

    # WITH ORDINALITY + ORDER BY: "first init" and "last completed probe" are positional
    # claims, and a set-returning function's output order is not contractually the input
    # order.
    CANDIDATE_LINE_SQL = <<~SQL.squish
      SELECT candidate.line
      FROM raw_report_data,
           LATERAL unnest(string_to_array(raw_report_data.jsonl_data, chr(10)))
             WITH ORDINALITY AS candidate(line, ordinality)
      WHERE raw_report_data.report_id = :report_id
        AND candidate.line ~ :pattern
      ORDER BY candidate.ordinality
    SQL

    EMPTY = {
      completed_probes: [],
      started_at: nil,
      last_completed_probe: nil,
      present: false
    }.freeze

    # @param report [Report]
    # @param journal_updated_at [Time, nil, :unknown] raw_report_data.updated_at when the
    #   caller already has it. It is the cache version: the sync thread only writes when
    #   the journal content changed, so an unchanged timestamp means an unchanged answer.
    def self.for(report, journal_updated_at: :unknown)
      new(report, journal_updated_at: journal_updated_at)
    end

    def initialize(report, journal_updated_at: :unknown)
      @report = report
      @journal_updated_at = journal_updated_at
    end

    attr_reader :report

    def completed_probes
      @completed_probes ||= Set.new(payload[:completed_probes])
    end

    def completed_count
      completed_probes.size
    end

    # The run's own start, as garak recorded it. reports.start_time is not written until
    # Reports::Process ingests the journal, so during a run this is the only source.
    # First valid init, not last: a resumed run appends a second init, and the elapsed
    # time a user is judging covers the whole run, not the latest attempt.
    def started_at
      payload[:started_at]
    end

    def last_completed_probe
      payload[:last_completed_probe]
    end

    # Whether a journal exists at all. False both before the first sync lands and after
    # Reports::Cleanup deletes it -- callers must not read "no journal" as "no work done".
    def present?
      payload[:present]
    end

    private

    def payload
      @payload ||= cached_payload
    end

    def cached_payload
      version = journal_version
      # No journal row: nothing to read, and nothing worth a cache entry either.
      return EMPTY.dup if version.nil?

      Rails.cache.fetch(cache_key(version), expires_in: CACHE_TTL) { compute_payload }
    end

    # Scalar read, never the association: RawReportData's default select would pull the
    # whole jsonl_data blob back just to look at a timestamp. nil means the row is gone.
    def journal_version
      unless defined?(@journal_version)
        @journal_version =
          if @journal_updated_at == :unknown
            RawReportData.where(report_id: report.id).pick(:updated_at)
          else
            @journal_updated_at
          end
      end

      @journal_version
    end

    def cache_key(version)
      [ "reports/journal_summary", CACHE_VERSION, report.id, version.to_f ]
    end

    def compute_payload
      completed = Set.new
      started_at = nil
      last_probe = nil

      candidate_lines.each do |line|
        entry = parse_line(line)
        next if entry.nil?

        if entry["entry_type"] == "init"
          started_at ||= parse_time(entry["start_time"])
          next
        end

        next unless GarakEvalRowValidator.valid?(entry, require_probe_detector: true)

        completed.add(entry["probe"])
        last_probe = entry["probe"]
      end

      {
        completed_probes: completed.to_a,
        started_at: started_at,
        last_completed_probe: last_probe,
        # compute_payload only runs when the row exists; a journal holding attempts but
        # no eval or init line yet is still present, so presence is the row, not matches.
        present: true
      }
    end

    def candidate_lines
      ActiveRecord::Base.connection.select_values(
        ActiveRecord::Base.sanitize_sql_array(
          [ CANDIDATE_LINE_SQL, { report_id: report.id, pattern: CANDIDATE_LINE_PATTERN } ]
        )
      )
    end

    def parse_line(line)
      parsed = JSON.parse(line.to_s)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError, EncodingError
      nil
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
