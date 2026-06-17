require 'rails_helper'

RSpec.describe Detector, type: :model do
  describe 'validations' do
    it { is_expected.to validate_presence_of(:name) }

    describe 'uniqueness' do
      subject { create(:detector) }
      it { is_expected.to validate_uniqueness_of(:name) }
    end
  end

  describe 'associations' do
    it { is_expected.to have_many(:detector_results).dependent(:destroy) }
    it { is_expected.to have_many(:reports).through(:detector_results) }
    it { is_expected.to have_many(:probe_results) }
    it { is_expected.to have_many(:probes) }
  end

  describe 'scopes' do
    let!(:active_detector) { create(:detector) }
    let!(:deleted_detector) { create(:detector, deleted_at: 1.day.ago) }

    describe 'default scope' do
      it 'only returns active detectors' do
        expect(Detector.all).to include(active_detector)
        expect(Detector.all).not_to include(deleted_detector)
      end
    end

    describe '.with_deleted' do
      it 'returns all detectors including deleted ones' do
        expect(Detector.with_deleted).to include(active_detector, deleted_detector)
      end
    end

    describe '.deleted_only' do
      it 'returns only deleted detectors' do
        expect(Detector.deleted_only).to include(deleted_detector)
        expect(Detector.deleted_only).not_to include(active_detector)
      end
    end
  end

  describe 'soft deletion methods' do
    let(:detector) { create(:detector) }

    describe '#soft_delete!' do
      it 'sets deleted_at timestamp' do
        expect { detector.soft_delete! }.to change { detector.reload.deleted_at }.from(nil)
      end

      it 'does not actually destroy the record' do
        detector.soft_delete!
        expect(Detector.with_deleted.find(detector.id)).to eq(detector)
      end

      it 'removes the detector from default scope' do
        detector.soft_delete!
        expect(Detector.all).not_to include(detector)
      end
    end

    describe '#restore!' do
      let(:deleted_detector) { create(:detector, deleted_at: 1.day.ago) }

      it 'clears deleted_at timestamp' do
        expect { deleted_detector.restore! }.to change { deleted_detector.reload.deleted_at }.to(nil)
      end

      it 'makes detector visible in default scope again' do
        deleted_detector.restore!
        expect(Detector.all).to include(deleted_detector)
      end
    end

    describe '#deleted?' do
      it 'returns false for active detector' do
        expect(detector.deleted?).to be false
      end

      it 'returns true for deleted detector' do
        detector.soft_delete!
        expect(detector.deleted?).to be true
      end
    end
  end

  describe '.ransackable_attributes' do
    it 'returns the correct attributes' do
      expect(Detector.ransackable_attributes).to match_array([ "name", "created_at", "id", "updated_at" ])
    end
  end

  describe '.ransackable_associations' do
    it 'returns the correct associations' do
      expect(Detector.ransackable_associations).to match_array([ "detector_results", "reports", "probe_results", "probes" ])
    end
  end

  describe 'factory' do
    it 'has a valid factory' do
      expect(build(:detector)).to be_valid
    end

    it 'can have associated probes' do
      detector = create(:detector, :with_probes)
      expect(detector.probes.count).to eq(2)
    end
  end
end
