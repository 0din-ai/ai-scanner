# frozen_string_literal: true

require "rails_helper"

RSpec.describe "LLM judge evidence in the report views", type: :view do
  let(:company) { create(:company) }
  let(:report) { create(:report, :completed, company: company) }

  let(:decided) do
    { "surface_score" => 0.6, "final_score" => 0.0, "label" => "REFUSED", "confidence" => 0.92,
      "reason" => "Declines and offers safety information.", "cache" => "miss",
      "judge_error" => nil, "judge_skipped" => nil }
  end
  let(:kept) do
    { "surface_score" => 0.55, "final_score" => 0.55, "label" => nil, "cache" => "miss",
      "judge_error" => "timeout", "judge_skipped" => nil }
  end

  describe "admin/reports/_attempt_card" do
    def render_card(attempt)
      render partial: "admin/reports/attempt_card",
             locals: { attempt: attempt, index: 0, report: report, probe_result_id: 1 }
    end

    it "counts the outputs the judge decided out of those in its band" do
      render_card({ "prompt" => "p", "outputs" => %w[a b c], "attack_succeeded" => false,
                    "notes" => { "llm_judge" => [ decided, kept, nil ] } })

      expect(rendered).to include("Judged 1/2")
    end

    it "shows nothing for an attempt without judge notes" do
      render_card({ "prompt" => "p", "outputs" => [ "o" ], "notes" => {}, "attack_succeeded" => true })

      expect(rendered).not_to include("data-judge-badge")
    end
  end

  describe "admin/reports/_judge_evidence" do
    it "shows the verdict, the score change and the reason" do
      render partial: "admin/reports/judge_evidence", locals: { entry: decided }

      expect(rendered).to include("REFUSED", "detector 0.60", "final 0.00", "confidence 0.92",
                                  "Declines and offers safety information.")
    end

    it "says the detector score was kept when the judge did not decide" do
      render partial: "admin/reports/judge_evidence", locals: { entry: kept }

      expect(rendered).to include("kept detector score", "error: timeout")
    end

    it "escapes a model-written reason" do
      render partial: "admin/reports/judge_evidence", locals: { entry: decided.merge("reason" => "<script>x</script>") }

      expect(rendered).not_to include("<script>x</script>")
    end
  end

  describe "admin/reports/_statistics_section" do
    let(:config) { { "enabled" => true, "model" => "openai/gpt-4.1-mini" } }

    it "summarises the judge's work on a judged report" do
      report.update_columns(judge_config: config,
                            judge_stats: { "in_band" => 4, "judged" => 2, "demoted" => 1, "promoted" => 1 })

      render partial: "admin/reports/statistics_section", locals: { report: report }

      expect(rendered).to include("LLM judge decided 2 of 4 boundary outputs (1 demoted, 1 promoted); 2 kept the detector score.")
    end

    it "says when the launching worker had no key" do
      report.update_columns(judge_config: config, judge_stats: { "launch_status" => "key_missing" })

      render partial: "admin/reports/statistics_section", locals: { report: report }

      expect(rendered).to include("JUDGE_API_KEY was not set")
    end

    it "says nothing for a report created with the judge off" do
      render partial: "admin/reports/statistics_section", locals: { report: report }

      expect(rendered).not_to include("data-judge-summary")
    end
  end
end
