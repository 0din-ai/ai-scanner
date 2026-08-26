# frozen_string_literal: true

require "rails_helper"

# Detector has `default_scope { where(deleted_at: nil) }`, so soft-deleting one does
# not merely hide it from probe pickers -- it drops out of every association and join
# in the app. Historical reports then read probe_result.detector as nil, and detector
# breakdowns that join detectors lose those rows entirely.
#
# Hard-deleting one is worse: detector_results is `dependent: :destroy`, so the rows
# go for good, and the probe_results foreign key then aborts the whole sync partway.
#
# Repointing an existing probe's detector is enough to trigger both: the old detector
# is left holding only disabled probes, or no probes at all.
RSpec.describe SyncProbesJob, "detector retention", type: :job do
  subject(:job) { described_class.new }

  let(:company) { create(:company) }

  def cleanup!
    job.send(:cleanup_detectors)
  end

  describe "a detector that stored results and now has no probes" do
    let!(:detector) { Detector.create!(name: "0din.Retired") }
    let!(:report) { ActsAsTenant.with_tenant(company) { create(:report, company: company) } }
    let!(:probe) { create(:probe, detector: Detector.create!(name: "0din.Current")) }
    let!(:probe_result) do
      ActsAsTenant.with_tenant(company) do
        create(:probe_result, report: report, probe: probe, detector: detector)
      end
    end

    it "is not hard deleted" do
      expect { cleanup! }.not_to raise_error

      expect(Detector.with_deleted.exists?(detector.id)).to be(true)
    end

    it "keeps the stored result readable, not orphaned" do
      cleanup!

      expect(probe_result.reload.detector).to eq(detector)
    end
  end

  describe "a detector whose probes were all repointed elsewhere" do
    let!(:detector) { Detector.create!(name: "0din.Superseded") }
    let!(:disabled_probe) { create(:probe, detector: detector, enabled: false) }
    let!(:report) { ActsAsTenant.with_tenant(company) { create(:report, company: company) } }

    context "when a report recorded a detector-level result for it" do
      before do
        ActsAsTenant.with_tenant(company) do
          DetectorResult.create!(detector: detector, report: report, passed: 1, total: 4)
        end
      end

      it "is not soft deleted" do
        cleanup!

        expect(detector.reload.deleted_at).to be_nil
      end
    end

    context "when nothing references it any more" do
      it "is still retired" do
        cleanup!

        expect(Detector.with_deleted.find(detector.id).deleted_at).to be_present
      end
    end
  end

  describe "when no probe source has changed" do
    let!(:detector) { Detector.create!(name: "0din.HiddenByEarlierRun", deleted_at: 1.day.ago) }
    let!(:report) { ActsAsTenant.with_tenant(company) { create(:report, company: company) } }
    let!(:probe) { create(:probe, detector: Detector.create!(name: "0din.Other")) }

    before do
      ActsAsTenant.with_tenant(company) do
        create(:probe_result, report: report, probe: probe, detector: detector)
      end
      allow(job).to receive(:needs_sync?).and_return(false)
      allow(AutoUpdateScanProbesJob).to receive(:perform_later)
    end

    it "still repairs detectors an earlier cleanup hid" do
      # The repair is needed exactly where the sources have NOT changed: a deploy
      # shipping no probe-catalog edit must still reach it, or the installations that
      # need it most never get it.
      job.send(:perform_sync)

      expect(detector.reload.deleted_at).to be_nil
    end
  end

  describe "an installation that already ran the old cleanup" do
    let!(:detector) { Detector.create!(name: "0din.HiddenByEarlierRun", deleted_at: 1.day.ago) }
    let!(:report) { ActsAsTenant.with_tenant(company) { create(:report, company: company) } }
    let!(:probe) { create(:probe, detector: Detector.create!(name: "0din.Other")) }

    before do
      ActsAsTenant.with_tenant(company) do
        create(:probe_result, report: report, probe: probe, detector: detector)
      end
    end

    it "restores the detector its stored results still point at" do
      # Guarding future runs only stops the bleeding. A detector hidden by an earlier
      # run has no enabled probe, so a restore query that looks at probes alone leaves
      # every already-broken installation broken.
      cleanup!

      expect(detector.reload.deleted_at).to be_nil
    end
  end
end
