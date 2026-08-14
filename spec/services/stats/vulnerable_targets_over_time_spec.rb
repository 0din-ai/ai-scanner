require 'rails_helper'

RSpec.describe Stats::VulnerableTargetsOverTime do
  describe '#call' do
    let(:days) { 30 }
    let(:service) { described_class.new(days: days) }
    let!(:detector) { create(:detector) }

    context 'when no targets or reports exist' do
      it 'returns empty data' do
        result = service.call

        expect(result[:targets]).to eq([])
        expect(result[:dates].size).to eq(days + 1) # Today + past days
        expect(result[:data]).to eq([])
      end
    end

    context 'when targets and reports exist' do
      before do
        # Create targets
        @target1 = create(:target, name: 'Target 1')
        @target2 = create(:target, name: 'Target 2')
        @target3 = create(:target, name: 'Target 3')

        # Create scan
        scan = create(:complete_scan)

        # Create reports for Target 1 (most vulnerable)
        5.times do |i|
          report = create(:report, target: @target1, scan: scan, created_at: i.days.ago)
          create(:detector_result, report: report, detector: detector, passed: 3, total: 10)
          create(:probe_result, report: report, probe: create(:probe), detector: detector, passed: 3, total: 10)
        end

        # Create reports for Target 2 (second most vulnerable)
        3.times do |i|
          report = create(:report, target: @target2, scan: scan, created_at: i.days.ago)
          create(:detector_result, report: report, detector: detector, passed: 7, total: 10)
          create(:probe_result, report: report, probe: create(:probe), detector: detector, passed: 7, total: 10)
        end

        # Create reports for Target 3 (least vulnerable)
        1.times do |i|
          report = create(:report, target: @target3, scan: scan, created_at: i.days.ago)
          create(:detector_result, report: report, detector: detector, passed: 9, total: 10)
          create(:probe_result, report: report, probe: create(:probe), detector: detector, passed: 9, total: 10)
        end

        # Create older report that should be excluded from 30-day window
        old_report = create(:report, target: @target3, scan: scan, created_at: 35.days.ago)
        create(:detector_result, report: old_report, detector: detector, passed: 0, total: 10)
        create(:probe_result, report: old_report, probe: create(:probe), detector: detector, passed: 0, total: 10)
      end

      it 'returns targets sorted by average ASR (highest to lowest)' do
        result = service.call

        expect(result[:targets].size).to be <= 5
        expect(result[:targets]).to include('Target 1', 'Target 2', 'Target 3')

        # Get the ASR values for each target to understand the sorting
        target1_index = result[:targets].index('Target 1')
        target2_index = result[:targets].index('Target 2')
        target3_index = result[:targets].index('Target 3')

        # Target 3 has 90% ASR (9/10 = 90%) - should be first (highest ASR)
        # Target 2 has 70% ASR (7/10 = 70%) - should be second
        # Target 1 has 30% ASR (3/10 = 30%) - should be third (lowest ASR)
        expect(target3_index).to be < target2_index
        expect(target2_index).to be < target1_index
      end

      it 'formats dates correctly' do
        result = service.call

        # Verify date format is YYYY-MM-DD
        date_format = /^\d{4}-\d{2}-\d{2}$/
        expect(result[:dates].all? { |date| date =~ date_format }).to be true

        # Last date should be today
        expect(result[:dates].last).to eq(Time.zone.today.strftime("%Y-%m-%d"))

        # First date should be "days" days ago
        expect(result[:dates].first).to eq(days.days.ago.to_date.strftime("%Y-%m-%d"))
      end

      it 'calculates ASR scores correctly for each target' do
        result = service.call

        # Data should have the same length as targets
        expect(result[:data].size).to eq(result[:targets].size)

        # Each target's data should have entry for each date
        result[:data].each do |target_data|
          expect(target_data[:data].size).to eq(result[:dates].size)
        end

        # Find Target 1's data
        target1_data = result[:data].find { |data| data[:name] == 'Target 1' }

        # Calculate expected ASR for Target 1 (30% pass rate)
        expected_asr = 30.0 # (3 / 10 * 100)

        # Check that recent dates have the expected ASR
        target1_recent_asrs = target1_data[:data].compact.last(5)
        expect(target1_recent_asrs.all? { |asr| asr == expected_asr }).to be true
      end

      it 'sets nil for dates with no report data' do
        result = service.call

        # Each target should have some nil values for dates without reports
        result[:data].each do |target_data|
          nil_count = target_data[:data].count(&:nil?)
          expect(nil_count).to be > 0
        end
      end

      it 'honors the days parameter' do
        # Create a service with fewer days
        short_service = described_class.new(days: 2)
        result = short_service.call

        # Should only include 3 days (today + 2 previous days)
        expect(result[:dates].size).to eq(3)
        expect(result[:targets]).to include('Target 1', 'Target 2')

        # Target 3's report should still be included as it's within the window
        expect(result[:targets]).to include('Target 3')
      end
    end

    context 'with more than 5 targets' do
      before do
        scan = create(:complete_scan)

        # Create 7 targets with varying vulnerability levels
        7.times do |i|
          target = create(:target, name: "Target #{i+1}")
          # Create more reports for lower indexed targets to make them more "vulnerable"
          (7 - i).times do |j|
            report = create(:report, target: target, scan: scan, created_at: j.days.ago)
            create(:detector_result, report: report, detector: detector, passed: i, total: 10)
            create(:probe_result, report: report, probe: create(:probe), detector: detector, passed: i, total: 10)
          end
        end
      end

      it 'limits results to top 5 targets sorted by average ASR' do
        result = service.call

        expect(result[:targets].size).to eq(5)
        expect(result[:data].size).to eq(5)

        # Verify that the targets are sorted by ASR in descending order
        # Target creation: Target i has ASR = i/10 * 100 = i*10%
        # So Target 7 = 70%, Target 6 = 60%, etc.
        # But we only get top 5, so should be Target 7, 6, 5, 4, 3
        expected_order = [ 'Target 7', 'Target 6', 'Target 5', 'Target 4', 'Target 3' ]
        expect(result[:targets]).to eq(expected_order)
      end
    end
  end
end
