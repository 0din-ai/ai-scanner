# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reports::JsonExportPayload do
  let(:company) { create(:company) }
  let(:target) { ActsAsTenant.with_tenant(company) { create(:target, company: company) } }
  let(:report) do
    ActsAsTenant.with_tenant(company) { create(:report, :completed, company: company, target: target) }
  end

  def export(record = report)
    JSON.parse(described_class.new(record.reload).each.to_a.join)
  end

  def primary(doc)
    doc["runs"].find { |run| run["role"] == "primary" }
  end

  def variant_run(doc)
    doc["runs"].find { |run| run["role"] == "variant" }
  end

  def probe_result_with(attempts, on: report, probe_name: "Probe A", **attrs)
    ActsAsTenant.with_tenant(company) do
      create(:probe_result, report: on, probe: create(:probe, name: probe_name),
             attempts: attempts, **attrs)
    end
  end

  # Builds a scan that ran twice: a primary run and a variant child run.
  def with_variant_child(child_probe_names: [])
    ActsAsTenant.with_tenant(company) do
      child = create(:report, :completed, company: company, target: target, parent_report: report)
      industry = create(:threat_variant_industry, name: "automotive")
      sub = create(:threat_variant_subindustry, threat_variant_industry: industry, name: "oem")
      child_probe_names.each_with_index do |name, i|
        # The same probe the primary run measured, where there is one -- that is
        # the whole point of a variant run.
        probe = Probe.find_by(name: name) || create(:probe, name: name)
        variant = create(:threat_variant, threat_variant_subindustry: sub, probe: probe, prompt: "v#{i}")
        create(:probe_result, report: child, probe: probe, threat_variant_id: variant.id,
               passed: 7, total: 10,
               attempts: [ { "uuid" => "c#{i}", "prompt" => "vq", "outputs" => [ "vr" ] } ])
      end
      child
    end
  end

  it "emits a parseable document with the schema version" do
    probe_result_with([ { "uuid" => "a", "prompt" => "q", "outputs" => [ "r" ] } ])

    doc = export

    expect(doc["schema_version"]).to eq(described_class::SCHEMA_VERSION)
    expect(doc["runs"].size).to eq(1)
    expect(primary(doc)["report"]["id"]).to eq(report.id)
    expect(primary(doc)["probe_results"].size).to eq(1)
  end

  describe "runs" do
    # A scan with threat variants executes twice. Folding the child run's
    # attempts into the parent's probe rows made the counts disagree with the
    # evidence and silently dropped whole results.
    it "emits the variant child as its own run" do
      probe_result_with([ { "uuid" => "m", "prompt" => "q", "outputs" => [ "r" ] } ], probe_name: "Shared")
      with_variant_child(child_probe_names: [ "Shared" ])

      expect(export["runs"].map { |r| r["role"] }).to eq(%w[primary variant])
    end

    it "keeps a child probe result whose probe has no parent counterpart" do
      # Iterating the parent's probe_results only made this row and its evidence
      # vanish while the file still looked complete.
      probe_result_with([ { "uuid" => "m", "prompt" => "q", "outputs" => [ "r" ] } ], probe_name: "Shared")
      with_variant_child(child_probe_names: [ "Shared", "ChildOnly" ])

      names = variant_run(export)["probe_results"].map { |p| p["probe_name"] }

      expect(names).to include("ChildOnly")
    end

    it "keeps each run's own scores" do
      # The flattened shape reported the parent's numbers only, so the child's
      # 7/10 could not be recovered from the file at all.
      probe_result_with([ { "uuid" => "m", "prompt" => "q", "outputs" => [ "r" ] } ],
                        probe_name: "Shared", passed: 0, total: 1)
      with_variant_child(child_probe_names: [ "Shared" ])

      doc = export

      expect(primary(doc)["scores"]).to include("passed" => 0, "total" => 1)
      expect(variant_run(doc)["scores"]).to include("passed" => 7, "total" => 10)
    end

    it "never lists more attempts under a probe row than that row measured" do
      # The invariant the flattened shape broke: a row declaring 0/1 beside four
      # attempts is not a contract a consumer can act on.
      probe_result_with([ { "uuid" => "m", "prompt" => "q", "outputs" => [ "r" ] } ],
                        probe_name: "Shared", passed: 0, total: 1)
      with_variant_child(child_probe_names: [ "Shared" ])

      export["runs"].each do |run|
        run["probe_results"].each do |row|
          expect(row["attempts"].size).to be <= row["total"],
            "#{row['probe_name']} declares #{row['total']} but lists #{row['attempts'].size} attempts"
        end
      end
    end

    it "names the variant on the result rather than on each attempt" do
      probe_result_with([ { "uuid" => "m", "prompt" => "q", "outputs" => [ "r" ] } ], probe_name: "Shared")
      with_variant_child(child_probe_names: [ "Shared" ])

      doc = export

      expect(primary(doc)["probe_results"].first["variant"]).to be_nil
      expect(variant_run(doc)["probe_results"].first["variant"])
        .to include("industry" => "automotive", "subindustry" => "oem")
    end

    it "describes a directly exported child as a variant run" do
      probe_result_with([ { "uuid" => "m", "prompt" => "q", "outputs" => [ "r" ] } ], probe_name: "Shared")
      child = with_variant_child(child_probe_names: [ "Shared" ])

      doc = export(child)

      expect(doc["runs"].size).to eq(1)
      expect(doc["runs"].first["role"]).to eq("variant")
      expect(doc["runs"].first["report"]["parent_report_id"]).to eq(report.id)
    end

    it "emits one run for a report with no variants" do
      probe_result_with([ { "uuid" => "a", "prompt" => "q", "outputs" => [ "r" ] } ])

      expect(export["runs"].map { |r| r["role"] }).to eq([ "primary" ])
    end
  end

  describe "attempt de-duplication" do
    it "collapses an attempt's start and completion rows" do
      probe_result_with([
        { "uuid" => "a", "prompt" => "q", "outputs" => [ "r" ], "attack_succeeded" => nil },
        { "uuid" => "a", "prompt" => "q", "outputs" => [ "r" ], "attack_succeeded" => true }
      ])

      attempts = primary(export)["probe_results"].first["attempts"]

      expect(attempts.size).to eq(1)
      expect(attempts.first["attack_succeeded"]).to be(true)
    end

    it "keeps identical uuid-less rows, because a dropped response can be an attack" do
      row = { "prompt" => "same", "outputs" => [ "same" ] }
      probe_result_with([ row, row.dup ])

      expect(primary(export)["probe_results"].first["attempts"].size).to eq(2)
    end

    it "exports exactly what the report page displays" do
      pr = probe_result_with([
        { "uuid" => "a", "prompt" => "q", "outputs" => [ "r" ] },
        { "uuid" => "a", "prompt" => "q", "outputs" => [ "r" ] },
        { "prompt" => "no uuid", "outputs" => [ "x" ] }
      ])

      expect(primary(export)["probe_results"].first["attempts"].size).to eq(pr.displayed_attempts.size)
    end
  end

  describe "outputs" do
    it "numbers every generation" do
      probe_result_with([ { "uuid" => "a", "prompt" => "q", "outputs" => [ "first", "second" ] } ])

      outputs = primary(export)["probe_results"].first["attempts"].first["outputs"]

      expect(outputs.map { |o| o["index"] }).to eq([ 0, 1 ])
      expect(outputs.map { |o| o["response"] }).to eq([ "first", "second" ])
    end

    it "treats a bare hash as one response rather than its key/value pairs" do
      # Kernel#Array turns { "text" => "x" } into [["text", "x"]] and would
      # export two bogus responses. The evidence tab shows one; these agree.
      probe_result_with([ { "uuid" => "a", "prompt" => "q", "outputs" => { "text" => "only one" } } ])

      outputs = primary(export)["probe_results"].first["attempts"].first["outputs"]

      expect(outputs.size).to eq(1)
      expect(outputs.first["response"]).to eq({ "text" => "only one" })
    end

    it "treats a bare string as one response" do
      probe_result_with([ { "uuid" => "a", "prompt" => "q", "outputs" => "bare" } ])

      responses = primary(export)["probe_results"].first["attempts"].first["outputs"].map { |o| o["response"] }

      expect(responses).to eq([ "bare" ])
    end

    it "exports no responses when there are none" do
      probe_result_with([ { "uuid" => "a", "prompt" => "q" } ])

      expect(primary(export)["probe_results"].first["attempts"].first["outputs"]).to eq([])
    end
  end

  describe "hostile content" do
    # Prompts and responses are attacker-influenced by construction: the point of
    # a probe is to make a model emit something it should not. The document has
    # to survive whatever comes back and still parse.
    HOSTILE_TEXT = {
      "a quote and a backslash" => %(he said "hi" \\ bye),
      "braces and brackets" => '{"not":"json"}]}',
      "a newline and a tab" => "line\nnext\tcol",
      "a null byte" => "before\u0000after",
      "a literal backslash-u escape" => '\\ud800 literal',
      "a unicode line separator" => "a\u2028b\u2029c",
      "an emoji and a direction override" => "boom \u{1F4A5} \u202Egnirts",
      "a closing script tag" => "</script><script>alert(1)</script>",
      "a lone carriage return" => "before\rafter"
    }.freeze

    HOSTILE_TEXT.each do |name, text|
      it "survives #{name} in a prompt and a response" do
        probe_result_with([ { "uuid" => "a", "prompt" => text, "outputs" => [ text ] } ])

        attempt = primary(export)["probe_results"].first["attempts"].first

        expect(attempt["prompt"]).to eq(text)
        expect(attempt["outputs"].first["response"]).to eq(text)
      end
    end

    it "survives hostile text in a probe name" do
      hostile_name = %(Probe "quoted" \\ {broken})
      probe_result_with([ { "uuid" => "a", "prompt" => "q", "outputs" => [ "r" ] } ],
                        probe_name: hostile_name)

      expect(primary(export)["probe_results"].first["probe_name"]).to eq(hostile_name)
    end

    it "survives a structured prompt carrying hostile turns" do
      prompt = { "turns" => [ { "role" => "user", "content" => { "text" => %(a "b" \\ c) } } ] }
      probe_result_with([ { "uuid" => "a", "prompt" => prompt, "outputs" => [ "r" ] } ])

      expect(primary(export)["probe_results"].first["attempts"].first["prompt"]).to eq(prompt)
    end
  end

  describe "determinism" do
    it "produces byte-identical output apart from exported_at" do
      # A consumer diffing two exports of the same report should see only the
      # timestamp change.
      d1 = create(:detector, name: "zeta.Detector")
      d2 = create(:detector, name: "alpha.Detector")
      ActsAsTenant.with_tenant(company) do
        create(:detector_result, report: report, detector: d1, passed: 1, total: 2)
        create(:detector_result, report: report, detector: d2, passed: 0, total: 2)
      end
      probe_result_with([ { "uuid" => "a", "prompt" => "q", "outputs" => [ "r" ] } ])

      strip = ->(doc) { doc.sub(/"exported_at":"[^"]+"/, "TIMESTAMP") }
      first = strip.call(described_class.new(report.reload).each.to_a.join)
      second = strip.call(described_class.new(report.reload).each.to_a.join)

      expect(first).to eq(second)
    end

    it "orders detectors by name" do
      d1 = create(:detector, name: "zeta.Detector")
      d2 = create(:detector, name: "alpha.Detector")
      ActsAsTenant.with_tenant(company) do
        create(:detector_result, report: report, detector: d1, passed: 1, total: 2)
        create(:detector_result, report: report, detector: d2, passed: 0, total: 2)
      end

      expect(primary(export)["detectors"].map { |d| d["name"] })
        .to eq([ "alpha.Detector", "zeta.Detector" ])
    end
  end

  describe "scores" do
    it "reports nil asr when nothing was measurable" do
      # 0.0 would claim the target defended perfectly; nothing was measured.
      probe_result_with([], passed: 0, total: 0)

      expect(primary(export)["scores"]["asr"]).to be_nil
    end

    it "computes asr when there is a denominator" do
      probe_result_with([ { "uuid" => "a", "prompt" => "q", "outputs" => [ "r" ] } ],
                        passed: 1, total: 4)

      expect(primary(export)["scores"]["asr"]).to eq(25.0)
    end
  end

  describe "target" do
    it "still names a soft-deleted target rather than blowing up" do
      probe_result_with([ { "uuid" => "a", "prompt" => "q", "outputs" => [ "r" ] } ])
      name = target.name
      # Soft delete: Target's default scope hides it, which is what makes
      # report.target nil while historical_target still resolves it.
      ActsAsTenant.with_tenant(company) { target.update_columns(deleted_at: Time.current) }

      expect(primary(export)["target"]["name"]).to eq(name)
    end
  end

  describe "memory bounding" do
    it "holds at most BATCH_SIZE probe_result rows at once" do
      ActsAsTenant.with_tenant(company) do
        (described_class::BATCH_SIZE + 5).times do |i|
          create(:probe_result, report: report, probe: create(:probe, name: "Probe #{i}"),
                 attempts: [ { "uuid" => "u#{i}", "prompt" => "q", "outputs" => [ "r" ] } ])
        end
      end

      biggest = 0
      subscriber = ActiveSupport::Notifications.subscribe("instantiation.active_record") do |*, payload|
        biggest = [ biggest, payload[:record_count].to_i ].max if payload[:class_name] == "ProbeResult"
      end

      described_class.new(report.reload).each.to_a

      ActiveSupport::Notifications.unsubscribe(subscriber)
      expect(biggest).to be <= described_class::BATCH_SIZE
    end
  end
end
