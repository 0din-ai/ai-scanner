require 'rails_helper'

RSpec.describe ProbeResult, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:report) }
    it { is_expected.to belong_to(:probe) }
  end

  describe 'validations' do
  end

  describe 'attempts normalization' do
    it 'normalizes nil attempts to empty array before validation' do
      result = build(:probe_result, :nil_attempts)
      result.valid?
      expect(result.attempts).to eq([])
    end

    it 'preserves existing attempts array' do
      result = build(:probe_result, attempts: [ { "prompt" => "hello" } ])
      result.valid?
      expect(result.attempts).to eq([ { "prompt" => "hello" } ])
    end

    it 'saves with empty array when attempts is nil' do
      result = create(:probe_result, :nil_attempts)
      expect(result.reload.attempts).to eq([])
    end

    it 'normalizes nil attempts on update' do
      result = create(:probe_result)
      result.attempts = nil
      result.save!
      expect(result.reload.attempts).to eq([])
    end
  end

  describe 'factory' do
    it 'has a valid structure' do
      expect(build_stubbed(:probe_result)).to be_valid
    end

    it 'has a high score trait' do
      result = build_stubbed(:probe_result, :high_score)
      expect(result.max_score).to eq(5)
      expect(result.passed).to eq(10)
      expect(result.total).to eq(10)
    end

    it 'has a low score trait' do
      result = build_stubbed(:probe_result, :low_score)
      expect(result.max_score).to eq(1)
      expect(result.passed).to eq(0)
      expect(result.total).to eq(10)
    end
  end

  describe '#asr_percentage' do
    it 'calculates percentage correctly' do
      result = build_stubbed(:probe_result, passed: 25, total: 100)
      expect(result.asr_percentage).to eq(25)
    end

    it 'rounds to nearest integer' do
      result = build_stubbed(:probe_result, passed: 1, total: 3)
      expect(result.asr_percentage).to eq(33)
    end

    it 'returns 0 when total is zero' do
      result = build_stubbed(:probe_result, passed: 5, total: 0)
      expect(result.asr_percentage).to eq(0)
    end

    it 'returns 0 when total is nil' do
      result = build_stubbed(:probe_result, passed: 5, total: nil)
      expect(result.asr_percentage).to eq(0)
    end

    it 'returns 100 when all tests pass' do
      result = build_stubbed(:probe_result, passed: 10, total: 10)
      expect(result.asr_percentage).to eq(100)
    end

    it 'returns 0 when no tests pass' do
      result = build_stubbed(:probe_result, passed: 0, total: 10)
      expect(result.asr_percentage).to eq(0)
    end
  end

  describe 'counter cache callbacks' do
    let(:probe) { create(:probe) }
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan) }
    let(:detector) { create(:detector) }

    before do
      # Ensure probe starts with zero cached stats
      probe.update_columns(cached_passed_count: 0, cached_total_count: 0)
    end

    describe 'after_create_commit' do
      it 'increments probe cached stats' do
        expect {
          create(:probe_result, probe: probe, report: report, detector: detector,
                 passed: 5, total: 10)
        }.to change { probe.reload.cached_passed_count }.from(0).to(5)
         .and change { probe.reload.cached_total_count }.from(0).to(10)
      end

      it 'accumulates stats across multiple probe_results' do
        create(:probe_result, probe: probe, report: report, detector: detector,
               passed: 3, total: 8)

        report2 = create(:report, target: target, scan: scan)

        expect {
          create(:probe_result, probe: probe, report: report2, detector: detector,
                 passed: 2, total: 5)
        }.to change { probe.reload.cached_passed_count }.from(3).to(5)
         .and change { probe.reload.cached_total_count }.from(8).to(13)
      end

      it 'skips update when passed and total are zero' do
        expect {
          create(:probe_result, probe: probe, report: report, detector: detector,
                 passed: 0, total: 0)
        }.not_to change { probe.reload.cached_passed_count }
      end
    end

    describe 'after_destroy_commit' do
      it 'decrements probe cached stats' do
        result = create(:probe_result, probe: probe, report: report, detector: detector,
                       passed: 7, total: 15)
        probe.reload

        expect {
          result.destroy
        }.to change { probe.reload.cached_passed_count }.by(-7)
         .and change { probe.reload.cached_total_count }.by(-15)
      end

      it 'prevents negative counts via GREATEST' do
        # Create result with some stats
        result = create(:probe_result, probe: probe, report: report, detector: detector,
                       passed: 5, total: 10)

        # Manually set cached counts lower than the result values (simulating corruption)
        probe.update_columns(cached_passed_count: 2, cached_total_count: 3)

        # Destroy should not go negative
        result.destroy
        probe.reload

        expect(probe.cached_passed_count).to eq(0)
        expect(probe.cached_total_count).to eq(0)
      end
    end

    describe 'after_update_commit' do
      it 'adjusts stats when passed changes' do
        result = create(:probe_result, probe: probe, report: report, detector: detector,
                       passed: 2, total: 10)
        probe.reload
        original_total = probe.cached_total_count

        expect {
          result.update!(passed: 5)
        }.to change { probe.reload.cached_passed_count }.by(3)

        expect(probe.reload.cached_total_count).to eq(original_total)
      end

      it 'adjusts stats when total changes' do
        result = create(:probe_result, probe: probe, report: report, detector: detector,
                       passed: 5, total: 10)
        probe.reload
        original_passed = probe.cached_passed_count

        expect {
          result.update!(total: 20)
        }.to change { probe.reload.cached_total_count }.by(10)

        expect(probe.reload.cached_passed_count).to eq(original_passed)
      end

      it 'does not update cache when non-stats fields change' do
        result = create(:probe_result, probe: probe, report: report, detector: detector,
                       passed: 5, total: 10, max_score: 3)
        probe.reload
        original_passed = probe.cached_passed_count
        original_total = probe.cached_total_count

        result.update!(max_score: 5)
        probe.reload

        expect(probe.cached_passed_count).to eq(original_passed)
        expect(probe.cached_total_count).to eq(original_total)
      end
    end

    describe 'cascade delete via report' do
      it 'decrements stats when report is destroyed' do
        create(:probe_result, probe: probe, report: report, detector: detector,
               passed: 10, total: 20)
        probe.reload

        expect {
          report.destroy
        }.to change { probe.reload.cached_passed_count }.by(-10)
         .and change { probe.reload.cached_total_count }.by(-20)
      end

      it 'handles multiple probe_results in cascade delete' do
        report2 = create(:report, target: target, scan: scan)
        probe2 = create(:probe)
        probe2.update_columns(cached_passed_count: 0, cached_total_count: 0)

        create(:probe_result, probe: probe, report: report, detector: detector,
               passed: 5, total: 10)
        create(:probe_result, probe: probe2, report: report, detector: detector,
               passed: 3, total: 8)

        probe.reload
        probe2.reload

        report.destroy

        expect(probe.reload.cached_passed_count).to eq(0)
        expect(probe.reload.cached_total_count).to eq(0)
        expect(probe2.reload.cached_passed_count).to eq(0)
        expect(probe2.reload.cached_total_count).to eq(0)
      end
    end
  end
end
