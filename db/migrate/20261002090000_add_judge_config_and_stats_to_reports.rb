class AddJudgeConfigAndStatsToReports < ActiveRecord::Migration[8.1]
  def change
    # judge_config: the LLM judge configuration this report was created under, resolved
    # once like evaluation_threshold and never rewritten. {} means the judge was off.
    # judge_stats: aggregated from the attempts' judge notes when the report is processed.
    add_column :reports, :judge_config, :jsonb, null: false, default: {}
    add_column :reports, :judge_stats, :jsonb, null: false, default: {}
  end
end
