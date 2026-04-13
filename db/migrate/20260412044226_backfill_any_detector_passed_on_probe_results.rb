class BackfillAnyDetectorPassedOnProbeResults < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # passed > 0 is exact for post-max-merge rows; historical multi-detector
  # rows where the final detector defended may be missed (no reconstruction path).
  def up
    ProbeResult.reset_column_information
    ProbeResult.where("passed > 0").in_batches(of: 5_000).update_all(any_detector_passed: true)
  end

  def down
    # No-op: the column itself is removed by the companion migration on rollback.
  end
end
