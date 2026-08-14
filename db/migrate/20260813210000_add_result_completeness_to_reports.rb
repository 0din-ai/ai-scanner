class AddResultCompletenessToReports < ActiveRecord::Migration[8.1]
  def change
    # Result completeness is deliberately separate from `status`: a failed or stopped
    # scan can still carry usable partial evidence, and the two facts are read
    # independently by the UI and by aggregate metrics.
    add_column :reports, :result_completeness, :string
    add_index :reports, [ :company_id, :result_completeness ]
  end
end
