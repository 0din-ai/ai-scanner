# frozen_string_literal: true

class RecomputeScanAvgExcludingPartials < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # The previous recomputation (20260814120000) averaged every completed report, including
  # ones holding only partial results. Changing the calculation does not touch values it
  # already stored, and scans.avg_successful_attacks is read directly by the scans list and
  # serializers -- so on any database already at that migration, historical scans would keep
  # displaying and sorting by the inflated figure until some future report happened to
  # trigger a recalculation.
  #
  # Idempotent: recomputes from current data, so running it twice is harmless.
  def up
    Scan.reset_column_information
    Scan.where(id: Report.completed.select(:scan_id)).find_each(batch_size: 500) do |scan|
      ActsAsTenant.without_tenant { scan.with_lock { scan.send(:update_avg_successful_attacks!) } }
    end
  end

  # Rolling back one step restores code that averages every completed report, so the caches
  # this migration narrowed have to be widened again -- a one-step rollback never invokes
  # 20260814120000#down, and the list, sort and serializer paths read the column directly.
  def down
    Scan.reset_column_information
    Scan.where(id: Report.completed.select(:scan_id)).find_each(batch_size: 500) do |scan|
      ActsAsTenant.without_tenant do
        scan.with_lock do
          rates = Report.completed
                        .where(scan_id: scan.id)
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
