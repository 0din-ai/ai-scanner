require 'rails_helper'

RSpec.describe SyncProbesJob, type: :job do
  describe '#perform' do
    before do
      # Clean up all data before each test (respecting foreign key constraints)
      ActiveRecord::Base.connection.execute("DELETE FROM probes_taxonomy_categories")
      ActiveRecord::Base.connection.execute("DELETE FROM probes_scans")
      ActiveRecord::Base.connection.execute("DELETE FROM probes_techniques")
      Probe.delete_all
      Detector.delete_all
      DataSyncVersion.delete_all
      TaxonomyCategory.delete_all
      Technique.delete_all

      allow(AutoUpdateScanProbesJob).to receive(:perform_later)
    end

    it 'iterates registered probe sources' do
      source_instance = instance_double("GarakCommunityProbeSource", needs_sync?: true, sync: { success: true })
      allow(ProbeSourceRegistry).to receive(:sources).and_return([ GarakCommunityProbeSource ])
      allow(GarakCommunityProbeSource).to receive(:new).and_return(source_instance)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:warn)

      # Stub advisory lock
      lock_result = [ { "pg_try_advisory_lock" => true } ]
      allow(ActiveRecord::Base.connection).to receive(:execute).and_call_original
      allow(ActiveRecord::Base.connection).to receive(:execute)
        .with("SELECT pg_try_advisory_lock(#{SyncProbesJob::SYNC_LOCK_KEY})")
        .and_return(lock_result)
      allow(ActiveRecord::Base.connection).to receive(:execute)
        .with("SELECT pg_advisory_unlock(#{SyncProbesJob::SYNC_LOCK_KEY})")

      described_class.new.perform

      expect(source_instance).to have_received(:sync).with(anything)
    end

    it 'skips sources that do not need sync' do
      source_instance = instance_double("GarakCommunityProbeSource", needs_sync?: false, sync: nil)
      allow(ProbeSourceRegistry).to receive(:sources).and_return([ GarakCommunityProbeSource ])
      allow(GarakCommunityProbeSource).to receive(:new).and_return(source_instance)
      allow(Rails.logger).to receive(:info)

      lock_result = [ { "pg_try_advisory_lock" => true } ]
      allow(ActiveRecord::Base.connection).to receive(:execute).and_call_original
      allow(ActiveRecord::Base.connection).to receive(:execute)
        .with("SELECT pg_try_advisory_lock(#{SyncProbesJob::SYNC_LOCK_KEY})")
        .and_return(lock_result)
      allow(ActiveRecord::Base.connection).to receive(:execute)
        .with("SELECT pg_advisory_unlock(#{SyncProbesJob::SYNC_LOCK_KEY})")

      described_class.new.perform

      expect(source_instance).not_to have_received(:sync)
    end

    it 'skips if advisory lock is not acquired' do
      lock_result = [ { "pg_try_advisory_lock" => false } ]
      allow(ActiveRecord::Base.connection).to receive(:execute).and_call_original
      allow(ActiveRecord::Base.connection).to receive(:execute)
        .with("SELECT pg_try_advisory_lock(#{SyncProbesJob::SYNC_LOCK_KEY})")
        .and_return(lock_result)
      allow(Rails.logger).to receive(:info)

      expect(ProbeSourceRegistry).not_to receive(:sources)

      described_class.new.perform
    end

    it 'always triggers AutoUpdateScanProbesJob after sync' do
      source_instance = instance_double("GarakCommunityProbeSource", needs_sync?: true, sync: { success: true })
      allow(ProbeSourceRegistry).to receive(:sources).and_return([ GarakCommunityProbeSource ])
      allow(GarakCommunityProbeSource).to receive(:new).and_return(source_instance)
      allow(Rails.logger).to receive(:info)

      lock_result = [ { "pg_try_advisory_lock" => true } ]
      allow(ActiveRecord::Base.connection).to receive(:execute).and_call_original
      allow(ActiveRecord::Base.connection).to receive(:execute)
        .with("SELECT pg_try_advisory_lock(#{SyncProbesJob::SYNC_LOCK_KEY})")
        .and_return(lock_result)
      allow(ActiveRecord::Base.connection).to receive(:execute)
        .with("SELECT pg_advisory_unlock(#{SyncProbesJob::SYNC_LOCK_KEY})")

      described_class.new.perform

      expect(AutoUpdateScanProbesJob).to have_received(:perform_later)
    end
  end

  describe '#cleanup_detectors' do
    let(:job) { described_class.new }

    context 'when detectors have no probe references' do
      let!(:unreferenced_detector) { create(:detector, name: "unreferenced") }

      it 'hard deletes unreferenced detectors' do
        expect(Rails.logger).to receive(:info).with("Cleaning up detectors...")
        expect(Rails.logger).to receive(:info).with("Deleting unreferenced detector: unreferenced (ID: #{unreferenced_detector.id})")
        expect(Rails.logger).to receive(:info).with("Detector cleanup complete: 1 deleted, 0 soft deleted, 0 restored")

        job.send(:cleanup_detectors)

        expect { unreferenced_detector.reload }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context 'when detectors are only referenced by disabled probes' do
      let!(:detector) { create(:detector, name: "test_detector") }
      let!(:disabled_probe) { create(:probe, detector: detector, enabled: false) }

      it 'soft deletes detectors only referenced by disabled probes' do
        expect(Rails.logger).to receive(:info).with("Cleaning up detectors...")
        expect(Rails.logger).to receive(:info).with("Soft deleting detector (only referenced by disabled probes): test_detector (ID: #{detector.id})")
        expect(Rails.logger).to receive(:info).with("Detector cleanup complete: 0 deleted, 1 soft deleted, 0 restored")

        job.send(:cleanup_detectors)

        expect(detector.reload.deleted?).to be true
        expect(Detector.all).not_to include(detector)
        expect(Detector.with_deleted).to include(detector)
      end

      it 'does not soft delete already deleted detectors' do
        detector.soft_delete!

        expect(Rails.logger).to receive(:info).with("Cleaning up detectors...")
        expect(Rails.logger).to receive(:info).with("Detector cleanup complete: 0 deleted, 0 soft deleted, 0 restored")

        job.send(:cleanup_detectors)
      end
    end

    context 'when detectors are referenced by enabled probes' do
      let!(:detector) { create(:detector, name: "active_detector", deleted_at: 1.day.ago) }
      let!(:enabled_probe) { create(:probe, detector: detector, enabled: true) }

      it 'restores previously deleted detectors referenced by enabled probes' do
        expect(Rails.logger).to receive(:info).with("Cleaning up detectors...")
        expect(Rails.logger).to receive(:info).with("Restoring detector (referenced by an enabled probe or stored results): active_detector (ID: #{detector.id})")
        expect(Rails.logger).to receive(:info).with("Detector cleanup complete: 0 deleted, 0 soft deleted, 1 restored")

        job.send(:cleanup_detectors)

        expect(detector.reload.deleted?).to be false
        expect(Detector.all).to include(detector)
      end
    end

    context 'complex scenarios' do
      let!(:unreferenced_detector) { create(:detector, name: "unreferenced") }
      let!(:detector_with_disabled_probes) { create(:detector, name: "disabled_only") }
      let!(:detector_with_enabled_probes) { create(:detector, name: "enabled", deleted_at: 1.day.ago) }
      let!(:detector_with_mixed_probes) { create(:detector, name: "mixed") }

      let!(:disabled_probe1) { create(:probe, detector: detector_with_disabled_probes, enabled: false) }
      let!(:enabled_probe1) { create(:probe, detector: detector_with_enabled_probes, enabled: true) }
      let!(:disabled_probe2) { create(:probe, detector: detector_with_mixed_probes, enabled: false) }
      let!(:enabled_probe2) { create(:probe, detector: detector_with_mixed_probes, enabled: true) }

      it 'handles all scenarios correctly' do
        expect(Rails.logger).to receive(:info).with("Cleaning up detectors...")
        expect(Rails.logger).to receive(:info).with("Deleting unreferenced detector: unreferenced (ID: #{unreferenced_detector.id})")
        expect(Rails.logger).to receive(:info).with("Soft deleting detector (only referenced by disabled probes): disabled_only (ID: #{detector_with_disabled_probes.id})")
        expect(Rails.logger).to receive(:info).with("Restoring detector (referenced by an enabled probe or stored results): enabled (ID: #{detector_with_enabled_probes.id})")
        expect(Rails.logger).to receive(:info).with("Detector cleanup complete: 1 deleted, 1 soft deleted, 1 restored")

        job.send(:cleanup_detectors)

        expect { unreferenced_detector.reload }.to raise_error(ActiveRecord::RecordNotFound)
        expect(detector_with_disabled_probes.reload.deleted?).to be true
        expect(detector_with_enabled_probes.reload.deleted?).to be false
        expect(detector_with_mixed_probes.reload.deleted?).to be false
      end
    end
  end
end
