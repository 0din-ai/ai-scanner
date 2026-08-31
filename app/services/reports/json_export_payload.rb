# frozen_string_literal: true

module Reports
  # Serializes a report to JSON for the "Export to JSON" download.
  #
  # The document is a list of RUNS, not a flat list of probes. A scan with
  # threat variants executes twice -- a primary run and a variant child run --
  # and each run has its own scores, its own detector totals and its own probe
  # results. Flattening the child's attempts into the parent's probe rows loses
  # facts that cannot be recovered downstream:
  #
  #   * a probe row would declare the parent's passed/total beside a list of
  #     attempts drawn from both runs, so the counts and the evidence disagree
  #   * the child's own passed/total and detector totals disappear
  #   * a child probe_result whose probe has no parent counterpart vanishes
  #     entirely, and the file still looks complete
  #
  # A consumer cannot rebuild those counts from the attempts, because the
  # evaluated total is not the number of attempts shown -- provider filtering
  # and partial processing move them apart. So each run is emitted whole and a
  # consumer that wants the flat view the report page shows can build it with
  # runs.flat_map { |r| r[:probe_results].flat_map { |p| p[:attempts] } }.
  #
  # Emitted as a sequence of chunks rather than one Hash so the whole document
  # is never held in memory at once. This bounds the ActiveRecord ROWS held at
  # once, not total memory: each row drags its full attempts jsonb along, and
  # that is decoded the moment the row loads. BATCH_SIZE caps rows, not bytes.
  #
  # The caller is expected to spool this to a file before sending headers. Do
  # not assign it straight to a Rack response body: the first chunk goes out
  # before any probe_result has been read, so a failure part-way through would
  # commit a 200 and then truncate, handing the reader a corrupt download that
  # looks like a success.
  class JsonExportPayload
    include Enumerable

    SCHEMA_VERSION = 1

    # How many probe_result ROWS are held at once. See the class comment for
    # what this does and does not bound.
    BATCH_SIZE = 25

    attr_reader :report

    def initialize(report)
      @report = report
    end

    # Yields the JSON document as a sequence of strings.
    def each
      return enum_for(:each) unless block_given?

      yield %({"schema_version":#{SCHEMA_VERSION})
      yield %(,"exported_at":#{Time.current.iso8601.to_json})

      yield %(,"runs":[)
      runs.each_with_index do |run, position|
        yield "," unless position.zero?
        emit_run(run) { |chunk| yield chunk }
      end
      yield "]}"
    end

    private

    # The report asked for, plus its variant child when it has one. Exporting a
    # child directly yields just that child, so a variant run is never described
    # as a primary one.
    def runs
      [ report, variant_child_report ].compact
    end

    def emit_run(run)
      head = {
        role: run.parent_report_id.present? ? "variant" : "primary",
        report: report_metadata(run),
        target: target_metadata(run),
        scores: scores(run),
        detectors: detector_breakdown(run)
      }

      yield %(#{head.to_json.chop},"probe_results":[)
      first = true
      each_probe_result(run) do |probe_result|
        yield "," unless first
        first = false
        emit_probe_row(probe_result) { |chunk| yield chunk }
      end
      yield "]}"
    end

    def report_metadata(run)
      {
        id: run.id,
        uuid: run.uuid,
        parent_report_id: run.parent_report_id,
        status: run.status,
        created_at: run.created_at.iso8601,
        started_at: run.start_time&.iso8601,
        completed_at: run.end_time&.iso8601,
        result_completeness: run.result_completeness
      }
    end

    # Resolved through Report#historical_target, which reads Target.with_deleted:
    # Target's default scope hides soft-deleted rows, so `run.target` is nil for
    # an archived target and dereferencing it would 500 an export the report page
    # still offers.
    #
    # historical_target can itself return nil -- it bails on a blank target_id or
    # company -- so every field stays nullable and the name falls back to the
    # same constant the rest of the app shows.
    def target_metadata(run)
      target = run.historical_target

      {
        id: target&.id,
        name: target&.name || Report::UNKNOWN_TARGET_NAME,
        model: target&.model,
        model_type: target&.model_type
      }
    end

    def scores(run)
      total = run.cached_total

      {
        passed: run.cached_passed,
        total: total,
        asr: asr(run.cached_passed, total)
      }
    end

    # nil, not 0.0, when nothing was measurable. 0.0 asserts "measured, nothing
    # succeeded"; a report whose every prompt was provider-filtered measured
    # nothing at all, and reporting that as 0% reads as a perfectly defended
    # target. Mirrors Reports::AsrFigure, which keeps the two apart for the UI.
    def asr(passed, total)
      return nil if total.to_i.zero?

      (passed.to_f / total * 100).round(2)
    end

    # Ordered by name so two exports of the same report are byte-identical apart
    # from exported_at. detector_results comes back in whatever order the table
    # yields, which is not a contract a consumer diffing exports can rely on.
    def detector_breakdown(run)
      run.detector_results.map { |dr|
        {
          name: detector_names[dr.detector_id] || "Unknown",
          passed: dr.passed,
          total: dr.total,
          asr: asr(dr.passed, dr.total)
        }
      }.sort_by { |row| [ row[:name], row[:total].to_i, row[:passed].to_i ] }
    end

    # Resolves detector names through with_deleted so retired detectors still
    # appear with their real name rather than nil, across every run, so two runs
    # never disagree about one detector's display name.
    #
    # The probe_result ids come from a pluck rather than from loaded rows: going
    # through the association would materialize every probe_result -- attempts
    # jsonb included -- before the first chunk was built.
    def detector_names
      @detector_names ||= begin
        ids = runs.flat_map { |run|
          run.probe_results.distinct.pluck(:detector_id) + run.detector_results.map(&:detector_id)
        }.compact.uniq

        ids.any? ? Detector.with_deleted.where(id: ids).pluck(:id, :name).to_h : {}
      end
    end

    def each_probe_result(run, &block)
      # No explicit order: find_each forces primary-key order and warns about any
      # scope that disagrees, and primary-key order is what we want anyway.
      run.probe_results
         .includes(:probe, threat_variant: [ :threat_variant_industry, :threat_variant_subindustry ])
         .find_each(batch_size: BATCH_SIZE, &block)
    end

    # A probe row goes out in pieces rather than as one serialized Hash, so a
    # probe's attempts are never all held at once. `chop` drops the head object's
    # closing brace so `"attempts"` can be appended to it; the head always has
    # keys, so it is never the empty object.
    def emit_probe_row(probe_result)
      yield %(#{probe_head(probe_result).to_json.chop},"attempts":[)

      probe_result.displayed_attempts.each_with_index do |attempt, index|
        row = serialized_attempt(attempt, index)
        yield index.zero? ? row.to_json : ",#{row.to_json}"
      end

      yield "]}"
    end

    # passed/total/asr describe this probe_result, and the attempts beneath it
    # come from the same row, so the counts and the evidence always refer to the
    # same measurement. The variant a row belongs to is named here rather than
    # per attempt, because it is a property of the result.
    def probe_head(probe_result)
      {
        probe_name: probe_result.probe&.name || "Unknown",
        probe_guid: probe_result.probe&.guid,
        detector_name: detector_names[probe_result.detector_id] || "Unknown",
        passed: probe_result.passed,
        total: probe_result.total,
        asr: asr(probe_result.passed, probe_result.total),
        variant: variant_metadata(probe_result)
      }
    end

    def variant_metadata(probe_result)
      return nil if probe_result.threat_variant_id.blank?

      threat_variant = probe_result.threat_variant
      return nil if threat_variant.nil?

      # Machine-readable rather than the "Industry / Subindustry" label the UI
      # builds, so a consumer can group without parsing a display string.
      {
        threat_variant_id: threat_variant.id,
        industry: threat_variant.threat_variant_industry&.name,
        subindustry: threat_variant.threat_variant_subindustry&.name
      }
    end

    # De-duplicated through the same rule the report page and the evidence tab
    # use: garak writes an attempt twice (start + completion) sharing one uuid,
    # so rows sharing a uuid collapse and rows without one stay distinct. See
    # ProbeResult#displayed_attempts. A uuid-less row cannot be a lifecycle copy,
    # and dropping one loses a real response -- which can be a successful attack.
    #
    # Carries the per-attempt verdict through: Reports::Process records
    # attack_succeeded (tri-state -- nil means garak scored nothing) and
    # detector_scores on every attempt. Without them an export of a safety scan
    # ships every prompt and response but cannot say which attacks succeeded.
    # The rest of `notes` is deliberately left out: it is unbounded garak
    # payload, and score_percentage is the only part the UI reads.
    def serialized_attempt(attempt, index)
      {
        index: index,
        uuid: attempt["uuid"],
        prompt: attempt["prompt"],
        attack_succeeded: attempt["attack_succeeded"],
        detector_scores: attempt["detector_scores"],
        score_percentage: attempt.dig("notes", "score_percentage"),
        outputs: attempt_outputs(attempt["outputs"]).each_with_index.map do |output, output_index|
          {
            index: output_index,
            response: output
          }
        end
      }
    end

    # Kernel#Array is the wrong wrapper for a malformed outputs value: a hash
    # becomes its key/value pairs, so a { "text" => ... } output would export as
    # two bogus responses. This matches what the evidence tab shows for the same
    # attempt, so the export and the UI never disagree about an attempt's
    # responses.
    def attempt_outputs(outputs)
      case outputs
      when nil then []
      when Array then outputs
      else [ outputs ]
      end
    end

    def variant_child_report
      return @variant_child_report if defined?(@variant_child_report)

      @variant_child_report = report.has_variant_data? ? report.child_report : nil
    end
  end
end
