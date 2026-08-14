# frozen_string_literal: true

class RecalculateScanAvgSuccessfulAttacks < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # scans.avg_successful_attacks is a stored, indexed figure that was averaged over
  # detector_results, which counted one attack once per detector that judged it. It is
  # now averaged over probe_results, matching Report#asr and every report surface, so
  # the stored values have to be recomputed -- otherwise the scans list keeps sorting and
  # displaying the old definition indefinitely.
  #
  # Only scans holding completed reports can change; the rest already store 0.0.
  #
  # If workers keep running while this migration is applied, a report finishing in that
  # window recomputes the cache from the old definition. Restart workers as part of the
  # upgrade, or run `rake scanner:recalculate_scan_asr_cache` once it has settled.
  def up
    Scan.reset_column_information
    Scan.where(id: Report.completed.select(:scan_id)).find_each(batch_size: 500) do |scan|
      # Locked for the same reason as scanner:recalculate_scan_asr_cache: a report
      # completing mid-migration can otherwise be overwritten by a staler figure.
      ActsAsTenant.without_tenant { scan.with_lock { scan.send(:update_avg_successful_attacks!) } }
    end
  end

  # Rolling back the code without restoring these values would leave every migrated scan
  # holding a probe-based figure that the old code reads as a detector-based one -- wrong
  # on the scans list and in its indexed sort order, indefinitely for any scan without a
  # later report. The old definition is still derivable, so recompute it.
  def down
    Scan.reset_column_information
    Scan.where(id: Report.completed.select(:scan_id)).find_each(batch_size: 500) do |scan|
      ActsAsTenant.without_tenant do
        scan.with_lock do
        rates = Report.completed
                      .where(scan_id: scan.id)
                      .left_joins(:detector_results)
                      .group("reports.id")
                      .pluck(Arel.sql("COALESCE(SUM(detector_results.passed), 0)"),
                             Arel.sql("COALESCE(SUM(detector_results.total), 0)"))
                      .map { |passed, total| total.to_i.positive? ? (passed.to_f / total * 100) : 0.0 }

        value = rates.any? ? (rates.sum / rates.size).round(2) : 0.0
        scan.update_column(:avg_successful_attacks, value)
        end
      end
    end
  end
end
