# frozen_string_literal: true

require "rails_helper"

# The Evidence tab reads attempts through SQL while the drawer reads them through
# Ruby. Wherever the two answer the same question they must agree, or the list will
# show a row whose drawer says something else -- which is the confusion this feature
# exists to remove.
RSpec.describe Reports::EvidenceRows do
  let(:company) { create(:company) }
  let(:target) { ActsAsTenant.with_tenant(company) { create(:target, company: company) } }
  let(:report) do
    ActsAsTenant.with_tenant(company) { create(:report, :completed, company: company, target: target) }
  end

  def probe_result_with(attempts, probe_name: "P")
    ActsAsTenant.with_tenant(company) do
      create(:probe_result, report: report, probe: create(:probe, name: probe_name), attempts: attempts)
    end
  end

  def lifecycle_pair(uuid:, text:, prompt: "how is it made?")
    [
      { "uuid" => uuid, "prompt" => prompt, "outputs" => [ text ], "attack_succeeded" => nil },
      { "uuid" => uuid, "prompt" => prompt, "outputs" => [ text ], "attack_succeeded" => true }
    ]
  end

  describe "agreement with ProbeResult#displayed_attempts" do
    it "returns one row per displayed attempt, in the same order" do
      # The probe card and the evidence list must not disagree about how many
      # attempts a run has, nor about which came first.
      pr = probe_result_with(lifecycle_pair(uuid: "a", text: "one") +
                             lifecycle_pair(uuid: "b", text: "two"))

      rows = described_class.new(report.reload).rows

      expect(rows.map(&:uuid)).to eq(pr.displayed_attempts.map { |a| a["uuid"] })
    end

    it "collapses interleaved lifecycle rows without reordering them" do
      a = lifecycle_pair(uuid: "a", text: "one")
      b = lifecycle_pair(uuid: "b", text: "two")
      pr = probe_result_with([ a[0], b[0], a[1], b[1] ])

      rows = described_class.new(report.reload).rows

      expect(rows.map(&:uuid)).to eq(%w[a b])
      expect(rows.map(&:uuid)).to eq(pr.displayed_attempts.map { |a| a["uuid"] })
    end

    it "keeps identical uuid-less rows distinct" do
      # THE regression this port could have reintroduced. A lifecycle duplicate always
      # shares a uuid, so a row without one cannot be one -- collapsing two identical
      # uuid-less rows drops a genuine repeated answer, and a dropped response can be
      # a successful attack.
      row = { "prompt" => "same", "outputs" => [ "same" ] }
      pr = probe_result_with([ row, row.dup ])

      expect(described_class.new(report.reload).rows.size).to eq(2)
      expect(described_class.new(report.reload).rows.size).to eq(pr.displayed_attempts.size)
    end

    it "does not treat a non-string uuid as an identity" do
      # `->> 'uuid'` renders false as 'false' and [] as '[]', so a type-blind check
      # would merge unrelated malformed rows into one.
      pr = probe_result_with([
        { "uuid" => false, "prompt" => "a", "outputs" => [ "x" ] },
        { "uuid" => false, "prompt" => "b", "outputs" => [ "y" ] },
        { "uuid" => [], "prompt" => "c", "outputs" => [ "z" ] }
      ])

      expect(described_class.new(report.reload).rows.size).to eq(3)
      expect(described_class.new(report.reload).rows.size).to eq(pr.displayed_attempts.size)
    end
  end

  describe "attempt_index" do
    it "indexes the STORED array, gaps included" do
      # Malformed rows are dropped from the list but not renumbered, so the index the
      # drawer resolves still points at the row the reader clicked.
      probe_result_with([
        "not an object",
        { "uuid" => "a", "prompt" => "first", "outputs" => [ "x" ] }
      ])

      row = described_class.new(report.reload).rows.first
      stored = ProbeResult.last.attempts

      expect(stored[row.attempt_index]["uuid"]).to eq("a")
    end
  end

  describe "search" do
    it "matches text the drawer shows as the prompt" do
      probe_result_with([ { "uuid" => "a", "prompt" => "how is ricin made", "outputs" => [ "no" ] } ])

      expect(described_class.new(report.reload, query: "ricin").rows.size).to eq(1)
    end

    it "matches every generation, not only the first" do
      # The verdict is the max across generations, so a later one is often the text a
      # reader is hunting for.
      probe_result_with([ { "uuid" => "a", "prompt" => "q", "outputs" => [ "harmless", "the secret phrase" ] } ])

      expect(described_class.new(report.reload, query: "secret phrase").rows.size).to eq(1)
    end

    it "ignores a trailing assistant turn, exactly as the drawer's prompt does" do
      # That turn is the model's own reply echoed back; the drawer renders it as the
      # RESPONSE. Searching it as prompt text would match a phrase the prompt panel
      # never shows.
      attempt = {
        "uuid" => "a",
        "prompt" => { "turns" => [
          { "role" => "user", "content" => { "text" => "user question" } },
          { "role" => "assistant", "content" => { "text" => "echoed reply" } }
        ] },
        "outputs" => [ "out" ]
      }
      probe_result_with([ attempt ])
      rendered = TokenEstimator.extract_prompt_text(attempt["prompt"]).to_s

      expect(rendered).to include("user question")
      expect(rendered).not_to include("echoed reply")
      expect(described_class.new(report.reload, query: "user question").rows.size).to eq(1)
      expect(described_class.new(report.reload, query: "echoed reply").rows.size).to eq(0)
    end

    it "keeps an earlier assistant turn, which is genuine input" do
      attempt = {
        "uuid" => "a",
        "prompt" => { "turns" => [
          { "role" => "user", "content" => { "text" => "first" } },
          { "role" => "assistant", "content" => { "text" => "carried forward" } },
          { "role" => "user", "content" => { "text" => "second" } }
        ] },
        "outputs" => [ "out" ]
      }
      probe_result_with([ attempt ])

      expect(TokenEstimator.extract_prompt_text(attempt["prompt"])).to include("carried forward")
      expect(described_class.new(report.reload, query: "carried forward").rows.size).to eq(1)
    end

    it "treats a wildcard as literal text rather than a pattern" do
      probe_result_with([ { "uuid" => "a", "prompt" => "plain", "outputs" => [ "x" ] } ])

      expect(described_class.new(report.reload, query: "%").rows).to be_empty
    end

    # The list searches in SQL; the drawer renders in Ruby. Where they disagree a
    # reader follows a hit to a panel that does not contain it, or scrolls past
    # text the search swore was not there. This table walks the malformed shapes
    # real scans have produced and asserts they agree on every one.
    [
      [ "a string prompt", "plain text prompt", nil ],
      [ "a numeric prompt", 42, nil ],
      [ "an array prompt", [ "a", "b" ], nil ],
      [ "turns that are not an array", { "turns" => "not an array" }, nil ],
      [ "a turn whose content is an array", { "turns" => [ { "role" => "user", "content" => [ "x" ] } ] }, nil ],
      [ "a string output", nil, [ "output text here" ] ],
      [ "an object output", nil, [ { "text" => "object output text" } ] ],
      [ "a bare string output", nil, "bare output" ],
      [ "a bare hash output", nil, { "text" => "bare hash output" } ],
      [ "a numeric output", nil, [ 7 ] ]
    ].each do |name, prompt, outputs|
      it "agrees between search and the drawer for #{name}" do
        attempt = { "uuid" => "a" }
        attempt["prompt"] = prompt unless prompt.nil?
        attempt["outputs"] = outputs unless outputs.nil?
        probe_result_with([ attempt ])

        # Exactly what the drawer renders, through the same calls the controller makes.
        drawer = [ TokenEstimator.extract_prompt_text(attempt["prompt"]).to_s ]
        drawer += case attempt["outputs"]
        when nil then []
        when Array then attempt["outputs"]
        else [ attempt["outputs"] ]
        end.map { |o| TokenEstimator.extract_output_text(o).to_s }

        words = drawer.join(" ").split(/\s+/).reject { |w| w.length < 4 }

        words.each do |word|
          expect(described_class.new(report.reload, query: word).rows.size).to eq(1),
            "#{name}: drawer shows #{word.inspect} but search does not match it"
        end

        # And nothing the drawer does not show may match.
        expect(described_class.new(report.reload, query: "zzz-absent-zzz").rows).to be_empty
      end
    end

    it "survives malformed turns and outputs" do
      probe_result_with([
        { "uuid" => "a", "prompt" => { "turns" => "not an array" }, "outputs" => "bare string" },
        { "uuid" => "b", "prompt" => nil, "outputs" => nil }
      ])

      expect { described_class.new(report.reload, query: "anything").rows }.not_to raise_error
      expect(described_class.new(report.reload).rows.size).to eq(2)
    end
  end

  describe "counts" do
    it "ignores the outcome filter so the chips keep showing what they would select" do
      probe_result_with([
        { "uuid" => "a", "prompt" => "q", "outputs" => [ "x" ], "attack_succeeded" => true },
        { "uuid" => "b", "prompt" => "q", "outputs" => [ "x" ], "attack_succeeded" => false }
      ])

      counts = described_class.new(report.reload, filter: "succeeded").counts

      expect(counts[:all]).to eq(2)
      expect(counts[:succeeded]).to eq(1)
      expect(counts[:blocked]).to eq(1)
    end

    it "honours the search, so the numbers agree with the table beneath them" do
      probe_result_with([
        { "uuid" => "a", "prompt" => "findme", "outputs" => [ "x" ], "attack_succeeded" => true },
        { "uuid" => "b", "prompt" => "other", "outputs" => [ "x" ], "attack_succeeded" => false }
      ])

      expect(described_class.new(report.reload, query: "findme").counts[:all]).to eq(1)
    end
  end

  describe "filters" do
    it "shows everything for an unrecognised filter rather than nothing" do
      probe_result_with([ { "uuid" => "a", "prompt" => "q", "outputs" => [ "x" ], "attack_succeeded" => true } ])

      expect(described_class.new(report.reload, filter: "nonsense").rows.size).to eq(1)
    end
  end

  describe "tenant isolation" do
    it "never reads another report's attempts" do
      probe_result_with([ { "uuid" => "mine", "prompt" => "q", "outputs" => [ "x" ] } ])

      other_company = create(:company)
      ActsAsTenant.with_tenant(other_company) do
        other_target = create(:target, company: other_company)
        other = create(:report, :completed, company: other_company, target: other_target)
        create(:probe_result, report: other, probe: create(:probe, name: "Other"),
               attempts: [ { "uuid" => "theirs", "prompt" => "q", "outputs" => [ "x" ] } ])
      end

      expect(described_class.new(report.reload).rows.map(&:uuid)).to eq([ "mine" ])
    end
  end
end
