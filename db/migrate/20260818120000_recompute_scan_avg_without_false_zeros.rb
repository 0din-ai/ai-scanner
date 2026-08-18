# frozen_string_literal: true

class RecomputeScanAvgWithoutFalseZeros < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Scan#calculate_avg_successful_attacks now returns nil when no report measured
  # anything, and no longer folds zero-total reports into the average. Changing the
  # calculation does not touch values already stored, and scans.avg_successful_attacks is
  # read directly by the scans list, its sort, the dashboard card and the stats endpoint --
  # so every historical scan would keep displaying the false 0.00 this fix removes.
  #
  # Scoped to all scans, not just those with a completed report: the rows most in need of
  # correction are the ones whose reports all failed, and those have no completed report
  # to select on.
  #
  # Idempotent: recomputes from current data, so running it twice is harmless.
  def up
    Scan.reset_column_information
    Scan.find_each(batch_size: 500) do |scan|
      ActsAsTenant.without_tenant { scan.with_lock { scan.send(:update_avg_successful_attacks!) } }
    end
  end

  # Rolling back restores code that stores 0.0 for an unmeasured scan and averages
  # zero-total reports as 0%, so the caches this migration nulled have to be refilled the
  # old way -- the list and serializer read the column directly.
  def down
    Scan.reset_column_information
    Scan.find_each(batch_size: 500) do |scan|
      ActsAsTenant.without_tenant do
        scan.with_lock do
          rates = Report.completed
                        .where(scan_id: scan.id)
                        .where("reports.result_completeness IS NULL OR reports.result_completeness <> 'partial'")
                        .left_joins(:probe_results)
                        .group("reports.id")
                        .pluck(Arel.sql("COALESCE(SUM(probe_results.passed), 0)"),
                               Arel.sql("COALESCE(SUM(probe_results.total), 0)"))
                        .map { |passed, total| total.to_i.positive? ? (passed.to_f / total * 100) : 0.0 }

          value = rates.any? ? (rates.sum / rates.size).round(2) : 0.0
          scan.update_column(:avg_successful_attacks, value)
        end
      end
    end
  end
end
