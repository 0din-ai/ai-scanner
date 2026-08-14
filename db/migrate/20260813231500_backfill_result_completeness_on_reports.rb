# frozen_string_literal: true

class BackfillResultCompletenessOnReports < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Classifies reports processed before result_completeness existed. Runs here rather
  # than as a deploy step so it happens automatically wherever migrations do, and only
  # touches terminal reports -- an in-flight one is classified by the worker that
  # finishes it, so this is safe to run while the previous version is still serving.
  #
  # Idempotent: only fills rows with no value. Reports whose failure the classifier
  # attributed to the provider are deliberately left unset when they hold results,
  # because such a run may have completed in full; see Report#backfill_result_completeness!.
  def up
    Report.reset_column_information
    Report.backfill_result_completeness!
  end

  def down
    # No-op: the column itself is removed by the companion migration on rollback.
  end
end
