class AddEvaluationThresholdToReports < ActiveRecord::Migration[8.1]
  # The evaluation threshold this report's run was launched with, resolved once at
  # creation and never rewritten -- not even by a retry.
  #
  # Processing re-resolved it from live config on every pass, because the value garak
  # reports in its start_run setup row never arrives: garak filters that row by type
  # and float is the one type it drops, so `run.eval_threshold` is absent and the
  # capture branch in Reports::Process is dead code. Re-resolving means an edit to
  # EVALUATION_THRESHOLD between launch and processing silently desyncs garak's own
  # passed count from the per-attempt success flags derived here, over the same items.
  #
  # Nullable: reports created before this column existed have no snapshot and keep the
  # old live-config behaviour. Backfilling would be a guess, since the value they ran
  # under is exactly what was never recorded.
  def change
    add_column :reports, :evaluation_threshold, :float, null: true
  end
end
