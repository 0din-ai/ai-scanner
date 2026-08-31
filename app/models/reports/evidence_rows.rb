# frozen_string_literal: true

module Reports
  # One flat, filterable list of every attempt in a report.
  #
  # Evidence used to be reachable only by expanding a probe card, then its
  # "Prompts & Responses" frame, then an attempt -- four interactions and two
  # sequential lazy frames deep, with no way to ask "which attacks got through?"
  # across the whole report. This flattens attempts into rows the Evidence tab
  # can filter, search and page.
  #
  # The flattening happens in SQL (json_array_elements + LIMIT), not in Ruby.
  # probe_results.attempts holds every prompt and output garak produced, so a
  # large report is tens of megabytes of JSON; loading it to build a page of 25
  # rows would put the whole report in memory. Postgres expands the array and
  # returns only the slice asked for, and only the prompt within it -- outputs
  # are never transferred for the list.
  class EvidenceRows
    DEFAULT_PER_PAGE = 25
    PREVIEW_LENGTH = 300

    # Only these reach SQL; anything else falls through to no outcome
    # condition, so a junk filter shows everything rather than nothing.
    FILTERS = {
      "succeeded" => "true",
      "blocked" => "false"
    }.freeze

    # The prompt and response text as the reader sees them, for search.
    #
    # Searching serialized JSON was wrong in both directions: it matched
    # structural keys the reader never sees, and it MISSED visible text,
    # because JSON escapes a quote as \" and a newline as \n -- so searching
    # for quoted speech, which these prompts are full of, returned nothing.
    # Walking every string leaf fixed the escaping but still matched turn
    # metadata (role: "user", lang: "en") and outputs the page never shows.
    #
    # So these are the renderer's own paths, mirrored: TokenEstimator takes a
    # string prompt as-is or joins turns[*].content(.text) with a NEWLINE, and
    # the drawer renders the FIRST output only. `#>> '{}'` yields each leaf
    # decoded.
    #
    # This mirrors TokenEstimator by construction; the specs pin both to the
    # same fixtures so the two cannot drift apart silently.
    # The outputs array, as Array() reads it: absent and null are both empty,
    # and a bare scalar is a one-element array. Shared by the identity key and
    # the searchable text -- they disagreed once, and the half that did not
    # normalise handed jsonb_array_elements a scalar and took the whole search
    # down with a PG::InvalidParameterValue.
    def self.outputs_array(value)
      <<~SQL.squish
        (CASE COALESCE(json_typeof(#{value} -> 'outputs'), 'null')
           WHEN 'array' THEN (#{value} -> 'outputs')::jsonb
           WHEN 'null' THEN '[]'::jsonb
           ELSE jsonb_build_array(#{value} -> 'outputs')
         END)
      SQL
    end
    private_class_method :outputs_array

    def self.text_at(expression, path)
      <<~SQL.squish
        COALESCE((SELECT string_agg(leaf #>> '{}', ' ')
                  FROM jsonb_path_query(#{expression}, '#{path}') leaf
                  WHERE jsonb_typeof(leaf) = 'string'), '')
      SQL
    end
    private_class_method :text_at

    # Turn contents, in the order TokenEstimator walks them and joined with the
    # same newline, so the searchable text IS the rendered text.
    #
    # One aggregation over the turns rather than one per content shape: taking
    # `content` and `content.text` separately put every string turn before every
    # structured one, so a phrase inside one turn could land beside text from a
    # turn three positions away. WITH ORDINALITY holds the order that string_agg
    # would otherwise be free to lose.
    #
    # A single-line search box strips newlines, so no query can span a turn
    # boundary either way. The newline is the separator that does not invent a
    # match the page never shows.
    # Drops a FINAL assistant turn, and only a final one, exactly as
    # TokenEstimator.extract_prompt_text does. That turn is the model's own reply
    # echoed back, which the drawer shows as the RESPONSE -- searching it as prompt
    # text would match the same phrase twice and let a reader match text the prompt
    # panel never shows. Earlier assistant turns stay: a multi-turn probe resends them
    # as genuine input.
    #
    # No `--` comments inside the SQL: these heredocs are squished onto one line, so a
    # line comment would swallow the rest of the query.
    def self.turn_text(expression)
      <<~SQL.squish
        COALESCE((SELECT string_agg(t.txt, E'\\n' ORDER BY t.ord)
                  FROM (SELECT turn.ord,
                               CASE jsonb_typeof(turn.value -> 'content')
                                 WHEN 'string' THEN turn.value ->> 'content'
                                 WHEN 'object' THEN turn.value -> 'content' ->> 'text'
                               END AS txt,
                               turn.value ->> 'role' AS role,
                               COUNT(*) OVER () AS turn_count
                        FROM jsonb_path_query(#{expression}, '$.turns[*]')
                          WITH ORDINALITY AS turn(value, ord)) t
                  WHERE t.txt IS NOT NULL
                    AND NOT (t.ord = t.turn_count AND t.role = 'assistant')), '')
      SQL
    end
    private_class_method :turn_text

    PROMPT_JSON = "COALESCE(elem.value -> 'prompt', 'null'::json)::jsonb"
    OUTPUTS_JSON = outputs_array("elem.value")

    # Every generation, in order, because the drawer shows every generation --
    # the verdict is the max across all of them, so the later ones are often
    # the text a reader is hunting for. Each is a string or a {text: ...}
    # object, and they are separated like the other fields so a query cannot
    # match a phrase running across two of them.
    def self.output_text(expression)
      <<~SQL.squish
        COALESCE((SELECT string_agg(
                    CASE jsonb_typeof(output.value)
                      WHEN 'string' THEN output.value #>> '{}'
                      WHEN 'object' THEN output.value ->> 'text'
                    END, #{FIELD_SEPARATOR} ORDER BY output.ord)
                  FROM jsonb_array_elements(#{expression})
                    WITH ORDINALITY AS output(value, ord)), '')
      SQL
    end
    private_class_method :output_text

    # The prompt and the response are separate panels in the drawer, and a
    # string prompt and a turn-structured one are alternatives -- only one of
    # each pair is ever non-empty. Joining the pieces with a unit separator
    # rather than a space keeps a search from matching a phrase that spans two
    # of them, which is text that appears nowhere on the page.
    #
    # The search box cannot type one, but a URL can percent-encode it, so the
    # query is stripped of it rather than trusted to lack it.
    FIELD_SEPARATOR = "E'\\x1f'"
    SEPARATOR_CHARACTER = "\u001f"

    SEARCHABLE_TEXT = "(#{[
      text_at(PROMPT_JSON, '$'),
      turn_text(PROMPT_JSON),
      output_text(OUTPUTS_JSON)
    ].join(" || #{FIELD_SEPARATOR} || ")})".freeze

    Row = Struct.new(
      :probe_result_id, :attempt_index, :uuid, :probe_name, :probe_guid,
      :detector_name, :succeeded, :score, :prompt_preview, :variant,
      keyword_init: true
    ) do
      def status
        return "unknown" if succeeded.nil?

        succeeded ? "succeeded" : "blocked"
      end
    end

    def initialize(report, filter: nil, query: nil)
      @report = report
      @filter = FILTERS[filter.to_s]
      @query = query.to_s.delete(SEPARATOR_CHARACTER).strip.presence
    end

    def rows(limit: DEFAULT_PER_PAGE, offset: 0)
      sql = <<~SQL.squish
        SELECT pr.id AS probe_result_id,
               pr.threat_variant_id AS threat_variant_id,
               elem.ord - 1 AS attempt_index,
               elem.value ->> 'uuid' AS uuid,
               elem.value ->> 'attack_succeeded' AS attack_succeeded,
               elem.value -> 'notes' ->> 'score_percentage' AS score,
               elem.value -> 'prompt' AS prompt,
               p.name AS probe_name,
               p.guid AS probe_guid,
               d.name AS detector_name
        #{from_clause}
        ORDER BY (pr.report_id <> :report_id), pr.id, elem.first_ord
        LIMIT :limit OFFSET :offset
      SQL

      select(sql, limit: limit.to_i, offset: offset.to_i).map { |record| build_row(record) }
    end

    # Totals for the filter chips. Deliberately ignores the outcome filter --
    # the chips have to keep showing what the other chips would select -- but
    # honours the search, so the numbers agree with the table beneath them.
    def counts
      @counts ||= compute_counts
    end

    # Which page a deep-linked attempt falls on, or nil when it is not in the
    # filtered set. A deep link has to work on a report with thousands of
    # attempts, where the row is rarely on the first page.
    #
    # Identified by probe result and index rather than uuid: garak assigns one
    # uuid per evaluated item and emits a row per generation reusing it (see
    # ProbeResult.displayed_attempt_key), so a uuid can match several attempts and
    # a link would always open the first generation.
    def page_for(probe_result_id:, attempt_index:, per_page: DEFAULT_PER_PAGE)
      return nil if probe_result_id.blank? || attempt_index.blank?

      sql = <<~SQL.squish
        SELECT page FROM (
          SELECT pr.id AS probe_result_id,
                 elem.ord - 1 AS attempt_index,
                 ((ROW_NUMBER() OVER (ORDER BY (pr.report_id <> :report_id), pr.id, elem.first_ord) - 1)
                   / :per_page) + 1 AS page
          #{from_clause}
        ) positioned
        WHERE positioned.probe_result_id = :probe_result_id
          AND positioned.attempt_index = :attempt_index
        LIMIT 1
      SQL

      select(sql, per_page: per_page.to_i,
                  probe_result_id: probe_result_id.to_i,
                  attempt_index: attempt_index.to_i).first&.fetch("page")&.to_i
    end

    # The attempts either side of one row, and its position in the whole
    # filtered set.
    #
    # The drawer steps from one attempt to the next, and the list is paged:
    # stepping through the rendered rows stopped at the page boundary, where a
    # 60-attempt report read "25 of 25" and would go no further. The server
    # already owns the de-duplicated, filtered ordering, so it is what answers
    # which attempt comes next -- the client then follows an identity rather
    # than a row that may not be rendered.
    #
    # nil when the row is not in the filtered set at all (a deep link to an
    # attempt the active filter hides): there is no neighbour to offer, and
    # stepping to an arbitrary one would be worse than not stepping.
    def neighbours(probe_result_id:, attempt_index:)
      sql = <<~SQL.squish
        WITH ordered AS (
          SELECT pr.id AS probe_result_id,
                 elem.ord - 1 AS attempt_index,
                 ROW_NUMBER() OVER (ORDER BY (pr.report_id <> :report_id), pr.id, elem.first_ord) AS position,
                 COUNT(*) OVER () AS total
          #{from_clause}
        ), anchor AS (
          SELECT position, total FROM ordered
          WHERE probe_result_id = :probe_result_id AND attempt_index = :attempt_index
          LIMIT 1
        )
        SELECT anchor.position, anchor.total,
               prev.probe_result_id AS prev_probe_result_id, prev.attempt_index AS prev_attempt_index,
               nxt.probe_result_id  AS next_probe_result_id, nxt.attempt_index  AS next_attempt_index
        FROM anchor
        LEFT JOIN ordered prev ON prev.position = anchor.position - 1
        LEFT JOIN ordered nxt  ON nxt.position  = anchor.position + 1
      SQL

      record = select(sql, probe_result_id: probe_result_id.to_i,
                           attempt_index: attempt_index.to_i).first
      return nil unless record

      {
        position: record["position"].to_i,
        total: record["total"].to_i,
        previous: coordinate(record, "prev"),
        next: coordinate(record, "next")
      }
    end

    # Size of the filtered set, for paging.
    #
    # Derived from #counts rather than its own aggregate: both expand every
    # attempt in the report, so running them separately re-parsed the whole
    # attempts payload a second time on every tab load, filter and page.
    def total
      case filter
      when "true" then counts[:succeeded]
      when "false" then counts[:blocked]
      else counts[:all]
      end
    end

    private

    attr_reader :report, :filter, :query

    def compute_counts
      sql = <<~SQL.squish
        SELECT COUNT(*) AS all_count,
               COUNT(*) FILTER (WHERE elem.value ->> 'attack_succeeded' = 'true') AS succeeded_count,
               COUNT(*) FILTER (WHERE elem.value ->> 'attack_succeeded' = 'false') AS blocked_count
        #{from_clause(apply_filter: false)}
      SQL

      record = select(sql).first
      {
        all: record["all_count"].to_i,
        succeeded: record["succeeded_count"].to_i,
        blocked: record["blocked_count"].to_i
      }
    end

    # One row per evaluated ITEM, mirroring ProbeResult.dedupe_key.
    #
    # garak writes each item twice -- attempt start and attempt completion --
    # and both copies carry the output text. Every other rendering path
    # collapses that pair through ProbeResult#displayed_attempts; expanding
    # pr.attempts directly bypassed it, so the flat list showed each
    # prompt/response twice and the chip counts doubled with it.
    #
    # Identity is the uuid when garak recorded one. Without a uuid it is the
    # prompt AND the outputs: two genuinely different responses to one prompt
    # would share a prompt-only key, and a dropped response can be a bypass.
    #
    # Blank is not a uuid. Ruby asks `uuid.present?`, so a whitespace-only value
    # falls through to the prompt; testing it for <> '' instead collapsed two
    # different prompts onto one row.
    #
    # Ruby's blank? is [[:space:]] over UTF-8, which is wider than the ASCII set
    # Postgres BTRIM defaults to -- a non-breaking space is blank to Rails and
    # not to a bare trim. The characters are listed so the two agree exactly
    # rather than nearly.
    #
    # Outputs go through outputs_array before being keyed, so the identity
    # reads them exactly as Array() does. Keying the raw JSON split rows that
    # Ruby collapses.
    #
    # One shape is deliberately NOT mirrored: Array() on a Hash yields its
    # pairs, so Ruby cannot tell {"text" => "x"} from [["text", "x"]]. That is
    # an accident of Array(), not a rule worth reproducing, and garak emits
    # neither -- outputs is an array of strings or of {text: ...} objects.

    # Ruby String#blank? is /\A[[:space:]]*\z/ over UTF-8. These are the
    # characters that matches, as a Postgres escape string.
    BLANK_CHARACTERS = "E'" \
      "\\u0009\\u000a\\u000b\\u000c\\u000d\\u0020\\u0085\\u00a0\\u1680" \
      "\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006\\u2007\\u2008\\u2009\\u200a" \
      "\\u2028\\u2029\\u202f\\u205f\\u3000'"

    # Identity for de-duplication, mirroring ProbeResult.displayed_attempt_key.
    #
    # garak writes each evaluated item twice -- attempt start and completion -- reusing
    # one uuid, so the uuid IS the item identity and collapsing on it is right.
    #
    # A row WITHOUT a usable uuid is deliberately left DISTINCT, keyed on its own
    # position. A lifecycle duplicate always shares a uuid, so a row lacking one cannot
    # be one; collapsing such rows on prompt-and-response would drop a genuine repeated
    # answer, and a dropped response can be a successful attack. That is the same rule
    # ProbeResult applies in Ruby, and the two must not disagree about how many rows
    # exist.
    #
    # The uuid branch requires a JSON STRING, not merely something that renders as
    # non-empty text. `->> 'uuid'` turns false into 'false' and [] into '[]', so a
    # type-blind check would treat several malformed rows as one item and silently
    # merge them. Anything that is not a nonblank string takes the ordinal path.
    DEDUPE_KEY = <<~SQL.squish
      CASE WHEN json_typeof(e.value -> 'uuid') = 'string'
                AND BTRIM(e.value ->> 'uuid', #{BLANK_CHARACTERS}) <> ''
           THEN 'uuid:' || (e.value ->> 'uuid')
           ELSE 'ord:' || e.ord::text
      END
    SQL

    # WITH ORDINALITY gives each attempt its position within its own probe
    # result, which is how evidence_attempt addresses it -- a flattened row is
    # useless without it. The ordinality is taken BEFORE de-duplication and
    # before malformed rows are dropped, so a surviving row still indexes the
    # stored array (gaps included), exactly as
    # ProbeResult#displayed_attempts reports it.
    #
    # Two ordinals, because the surviving row and its position are different
    # questions. `ord` is the LAST copy -- the completion one, carrying the
    # detector's verdict, and the index the drawer resolves. `first_ord` is the
    # earliest copy, and the list is ordered by it, because
    # displayed_attempts orders by first appearance: two items whose lifecycle
    # rows interleave would otherwise come out reversed from the probe card.
    def from_clause(apply_filter: true)
      clause = +<<~SQL.squish
        FROM probe_results pr
        CROSS JOIN LATERAL (
          SELECT DISTINCT ON (keyed.dedupe_key)
                 keyed.value,
                 keyed.ord,
                 MIN(keyed.ord) OVER (PARTITION BY keyed.dedupe_key) AS first_ord
          FROM (
            SELECT e.value, e.ord, #{DEDUPE_KEY} AS dedupe_key
            FROM json_array_elements(COALESCE(pr.attempts, '[]'::json))
              WITH ORDINALITY AS e(value, ord)
            WHERE json_typeof(e.value) = 'object'
          ) keyed
          ORDER BY keyed.dedupe_key, keyed.ord DESC
        ) AS elem(value, ord, first_ord)
        LEFT JOIN probes p ON p.id = pr.probe_id
        LEFT JOIN detectors d ON d.id = pr.detector_id
        WHERE pr.report_id IN (:report_ids)
      SQL

      clause << " AND elem.value ->> 'attack_succeeded' = :filter" if apply_filter && filter
      clause << " AND #{SEARCHABLE_TEXT} ILIKE :query" if query
      clause
    end

    # A variant parent holds only the main attempts; the variant attempts live
    # on its child report. Both belong in a list that claims to show every
    # attempt in the run.
    def report_ids
      @report_ids ||= [ report.id, (report.child_report&.id if report.has_variant_data?) ].compact
    end

    def select(sql, extra = {})
      binds = { report_id: report.id, report_ids: report_ids }
      binds[:filter] = filter if filter
      # sanitize_sql_like escapes % and _ so a searched wildcard is literal text
      # rather than a pattern that quietly matches everything.
      binds[:query] = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%" if query

      ProbeResult.connection.select_all(
        ActiveRecord::Base.sanitize_sql_array([ sql, binds.merge(extra) ])
      )
    end

    def coordinate(record, side)
      id = record["#{side}_probe_result_id"]
      return nil if id.nil?

      { probe_result_id: id, attempt_index: record["#{side}_attempt_index"].to_i }
    end

    def build_row(record)
      Row.new(
        probe_result_id: record["probe_result_id"],
        attempt_index: record["attempt_index"].to_i,
        uuid: record["uuid"],
        probe_name: record["probe_name"],
        probe_guid: record["probe_guid"],
        detector_name: record["detector_name"],
        succeeded: parse_boolean(record["attack_succeeded"]),
        score: record["score"]&.to_f,
        prompt_preview: preview(record["prompt"]),
        variant: record["threat_variant_id"].present?
      )
    end

    # nil is a third state, not a false: garak returned no detector scores for
    # this attempt, so neither "succeeded" nor "blocked" is a claim we can make.
    def parse_boolean(value)
      return nil if value.nil?

      value == "true"
    end

    # garak emits prompts as bare strings and as turn structures; the list must
    # show text either way rather than a Hash inspection.
    def preview(raw)
      return "" if raw.blank?

      parsed = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        raw
      end

      text = TokenEstimator.extract_prompt_text(parsed).to_s
      text.length > PREVIEW_LENGTH ? "#{text[0, PREVIEW_LENGTH - 1]}…" : text
    end
  end
end
