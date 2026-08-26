class SyncProbesJob < ApplicationJob
  queue_as :default
  # Advisory lock key for preventing concurrent sync execution
  SYNC_LOCK_KEY = 0x5359_4E43_5052_4F42  # "SYNCPROB" in hex

  def perform
    # Use PostgreSQL advisory lock to prevent concurrent execution
    # This prevents race conditions where multiple SyncProbesJob instances
    # could run simultaneously and cause probes to be missed by AutoUpdateScanProbesJob
    lock_acquired = ActiveRecord::Base.connection.execute(
      "SELECT pg_try_advisory_lock(#{SYNC_LOCK_KEY})"
    ).first["pg_try_advisory_lock"]

    unless lock_acquired
      Rails.logger.info "[SyncProbesJob] Another sync is already in progress, skipping"
      return
    end

    begin
      perform_sync
    ensure
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{SYNC_LOCK_KEY})")
    end
  end

  private

  def perform_sync
    # Runs on every sync, BEFORE the unchanged-source early return below.
    #
    # It repairs detectors an earlier cleanup hid, and that repair is needed exactly
    # where the sources have NOT changed -- a deploy that ships no probe-catalog edit
    # would otherwise never reach it, so the installations most in need of the repair
    # would never get it. The detector graph can also go stale without a source
    # change: probes are enabled and disabled independently of it.
    #
    # A handful of queries, and idempotent, so running it every tick costs nothing.
    cleanup_detectors

    # Skip if nothing has changed since last sync
    unless needs_sync?
      Rails.logger.info "[SyncProbesJob] Probe data unchanged since last sync, skipping"
      return
    end

    # Capture start time for AutoUpdateScanProbesJob (fixes timing bug)
    sync_start_time = Time.current

    had_failures = false

    ProbeSourceRegistry.sources.each do |source_class|
      source = source_class.new
      next unless source.needs_sync?

      result = source.sync(sync_start_time)
      had_failures = true if result && result[:success] == false
    end

    # Again after the sources ran: this pass is the one that acts on what they just
    # changed -- newly disabled probes, detectors a repoint left behind.
    cleanup_detectors

    if had_failures
      Rails.logger.warn "Some probe sources had sync failures — AutoUpdateScanProbesJob will run but affected sources were not fully synced"
    end
    AutoUpdateScanProbesJob.perform_later

    Rails.logger.info "Syncing probes...done"
  end

  def needs_sync?
    ProbeSourceRegistry.sources.any? { |source_class| source_class.new.needs_sync? }
  end

  # A detector cited by any stored result must survive cleanup, whichever query is
  # about to remove it. Shared so the two cannot drift apart.
  NOT_REFERENCED_BY_STORED_RESULTS = <<~SQL.squish
    NOT EXISTS (SELECT 1 FROM detector_results WHERE detector_results.detector_id = detectors.id)
    AND NOT EXISTS (SELECT 1 FROM probe_results WHERE probe_results.detector_id = detectors.id)
  SQL

  def cleanup_detectors
    Rails.logger.info "Cleaning up detectors..."

    # Detectors nothing references at all -- no probes, and no stored results.
    #
    # The stored-results half is not optional. detector_results is
    # `dependent: :destroy`, so hard-deleting a detector a report still cites throws
    # that report's rows away, and the probe_results foreign key then raises and
    # aborts the sync partway through, leaving the catalog half-updated.
    unreferenced_detectors = Detector.with_deleted
                                    .left_joins(:probes)
                                    .where(probes: { detector_id: nil })
                                    .where(NOT_REFERENCED_BY_STORED_RESULTS)
                                    .distinct

    # Detectors only reachable through disabled probes, and cited by no stored result.
    #
    # Detector has `default_scope { where(deleted_at: nil) }`, so soft-deleting one
    # does not merely hide it from probe pickers -- it drops out of every association
    # and join in the app. Historical reports then read `probe_result.detector` as nil
    # and vanish from any detector breakdown that joins detectors. Repointing a probe
    # family to a new detector is enough to trigger it: the old detector is left
    # holding only disabled probes, however much history still cites it.
    detectors_with_only_disabled_probes = Detector.with_deleted
                                                 .joins(:probes)
                                                 .where(probes: { enabled: false })
                                                 .where.not(id: Detector.with_deleted
                                                                       .joins(:probes)
                                                                       .where(probes: { enabled: true })
                                                                       .select(:id))
                                                 .where(NOT_REFERENCED_BY_STORED_RESULTS)
                                                 .distinct

    # Hard delete unreferenced detectors
    deleted_count = 0
    unreferenced_detectors.find_each do |detector|
      Rails.logger.info "Deleting unreferenced detector: #{detector.name} (ID: #{detector.id})"
      detector.destroy!
      deleted_count += 1
    end

    # Soft delete detectors only referenced by disabled probes
    soft_deleted_count = 0
    detectors_with_only_disabled_probes.find_each do |detector|
      unless detector.deleted?
        Rails.logger.info "Soft deleting detector (only referenced by disabled probes): #{detector.name} (ID: #{detector.id})"
        detector.soft_delete!
        soft_deleted_count += 1
      end
    end

    # Restore detectors that are referenced again -- by an enabled probe, OR by stored
    # results.
    #
    # The stored-results half is what repairs an installation that already ran the old
    # cleanup. Guarding the deletes above only stops the bleeding: a detector hidden by
    # an earlier run has no enabled probe, so a restore query looking at probes alone
    # would leave it hidden for good. It also unblocks probe sync itself -- the unique
    # index on detectors.name covers deleted rows too, so `find_or_create_by!` cannot
    # see the hidden row, tries to insert, and raises.
    restored_detectors = Detector.deleted_only.where(<<~SQL.squish).distinct
      EXISTS (SELECT 1 FROM probes WHERE probes.detector_id = detectors.id AND probes.enabled = TRUE)
      OR EXISTS (SELECT 1 FROM detector_results WHERE detector_results.detector_id = detectors.id)
      OR EXISTS (SELECT 1 FROM probe_results WHERE probe_results.detector_id = detectors.id)
    SQL
    restored_count = 0
    restored_detectors.find_each do |detector|
      Rails.logger.info "Restoring detector (referenced by an enabled probe or stored results): #{detector.name} (ID: #{detector.id})"
      detector.restore!
      restored_count += 1
    end

    Rails.logger.info "Detector cleanup complete: #{deleted_count} deleted, #{soft_deleted_count} soft deleted, #{restored_count} restored"
  end
end
