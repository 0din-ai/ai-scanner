class AddPlannedProbeCountToReports < ActiveRecord::Migration[8.1]
  def change
    # Recorded when the run is prepared, because the scan's probe list is mutable:
    # an edit or AutoUpdateScanProbesJob can add or remove probes afterwards, and a
    # variant child executes mapped variants rather than the scan's own probes.
    # Reading either at render time yields a ratio against a plan that was never run.
    # NULL means the plan is unknown (every report created before this column), and
    # callers show the processed count alone rather than a ratio.
    add_column :reports, :planned_probe_count, :integer
  end
end
