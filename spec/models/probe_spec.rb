require 'rails_helper'

RSpec.describe Probe, type: :model do
  describe 'associations' do
    it { is_expected.to have_and_belong_to_many(:scans) }
    it { is_expected.to have_and_belong_to_many(:techniques) }
    it { is_expected.to have_and_belong_to_many(:taxonomy_categories) }
    it { is_expected.to have_many(:probe_results) }
    it { is_expected.to belong_to(:detector).optional }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_uniqueness_of(:name) }
    it { is_expected.to validate_presence_of(:category) }
    it { is_expected.to validate_presence_of(:source) }
  end

  describe 'scopes' do
    describe '.enabled' do
      before do
        create(:probe, enabled: true)
        create(:probe, enabled: false)
      end

      it 'returns only enabled probes' do
        expect(Probe.enabled.count).to eq(1)
        expect(Probe.enabled.first.enabled).to be_truthy
      end
    end

    describe '.by_release_date' do
      it 'orders probes by release_date ascending' do
        newer = create(:probe, release_date: 1.month.ago)
        older = create(:probe, release_date: 1.year.ago)
        oldest = create(:probe, release_date: 2.years.ago)

        result = Probe.by_release_date

        expect(result.first).to eq(oldest)
        expect(result.last).to eq(newer)
      end
    end
  end

  describe '#full_name' do
    context 'for 0din probes' do
      it 'returns category.name format' do
        probe = create(:probe, name: "TestProbe", category: "0din", source: "0din")
        expect(probe.full_name).to eq("0din.TestProbe")
      end
    end

    context 'for garak probes' do
      it 'returns name as-is (already includes module)' do
        probe = create(:probe, name: "dan.Dan_11_0", category: "garak", source: "garak")
        expect(probe.full_name).to eq("dan.Dan_11_0")
      end

      it 'does not duplicate module prefix' do
        probe = create(:probe, name: "encoding.InjectBase64", category: "garak", source: "garak")
        expect(probe.full_name).to eq("encoding.InjectBase64")
        expect(probe.full_name).not_to eq("garak.encoding.InjectBase64")
      end
    end
  end

  describe '#variant_eligible?' do
    it 'is true when the detector is variant-eligible' do
      detector = build(:detector, name: '0din.MitigationBypass')
      probe = build(:probe, detector: detector)

      expect(probe.variant_eligible?).to be true
    end

    it 'is false when the detector is not variant-eligible' do
      detector = build(:detector, name: '0din.PromptInjection')
      probe = build(:probe, detector: detector)

      expect(probe.variant_eligible?).to be false
    end

    it 'is false when there is no detector' do
      probe = build(:probe, detector: nil)

      expect(probe.variant_eligible?).to be false
    end
  end
end
