# frozen_string_literal: true

namespace :scanner do
  # scans.avg_successful_attacks is stored and indexed, so the scans list sorts on it.
  # The migration that switched ASR to probe results recomputes it, but a worker still
  # running the previous code can finish a report afterwards and write the old figure
  # back. Run this once the upgrade has settled to reconcile those.
  #
  # Scoped to all scans, not just those with a completed report: an old-code worker can
  # fail a report and write the false 0.0 back for a scan with no completed report at
  # all, and that scan has no completed report to select on -- same reasoning as the
  # migration this task reconciles after (db/migrate/20260818120000_recompute_scan_avg_without_false_zeros.rb).
  #
  # Idempotent: it recomputes from current data.
  desc "Recompute stored scan ASR averages (run after an upgrade completes)"
  task recalculate_scan_asr_cache: :environment do
    updated = 0
    Scan.find_each(batch_size: 500) do |scan|
      before = scan.avg_successful_attacks
      # Locked: the recomputation reads every report for the scan and then writes the
      # cache, so without it a report completing mid-task can commit a newer value that
      # this task then overwrites with the one it computed before that report landed.
      ActsAsTenant.without_tenant { scan.with_lock { scan.send(:update_avg_successful_attacks!) } }
      updated += 1 if scan.reload.avg_successful_attacks != before
    end

    puts "Scan ASR cache: recomputed, #{updated} scan(s) changed"
  end
end
