require 'rails_helper'

RSpec.describe Stats::AttackFailsByTargetData do
  describe '#call' do
    let(:scan) { create(:complete_scan) }
    let(:detector) { create(:detector, name: 'detector.type1') }
    let(:detector2) { create(:detector, name: 'detector.type2') }

    subject { described_class.new }

    context 'when no data exists' do
      it 'returns empty data structure' do
        result = subject.call

        expect(result[:dates].length).to eq(30) # 30 days of dates
        expect(result[:targets]).to eq([])
        expect(result[:scan_summary][:total_reports]).to eq(0)
        expect(result[:scan_summary][:total_tests]).to eq(0)
        expect(result[:scan_summary][:total_passed]).to eq(0)
        expect(result[:scan_summary][:total_failed]).to eq(0)
        expect(result[:scan_summary][:detector_stats]).to eq({})
        expect(result[:scan_summary][:success_rate]).to eq(0)
        expect(result[:time_range]).to eq("Last 30 Days")
      end
    end

    context 'when data exists for multiple targets' do
      let!(:target1) { create(:target, name: 'Target 1', model_type: 'OpenAIGenerator', model: 'gpt-3.5-turbo') }
      let!(:target2) { create(:target, name: 'Target 2', model_type: 'OpenAIGenerator', model: 'claude-2') }

      before do
        # Create reports and detector results for Target 1
        report1 = create(:report, target: target1, scan: scan, created_at: Time.zone.today)
        create(:detector_result, report: report1, detector: detector, passed: 8, total: 10)
        create(:detector_result, report: report1, detector: detector2, passed: 5, total: 10)

        # Create another report for Target 1 from a different date
        report2 = create(:report, target: target1, scan: scan, created_at: 2.days.ago)
        create(:detector_result, report: report2, detector: detector, passed: 6, total: 10)

        # Create reports and detector results for Target 2
        report3 = create(:report, target: target2, scan: scan, created_at: Time.zone.today)
        create(:detector_result, report: report3, detector: detector, passed: 3, total: 10)
        create(:detector_result, report: report3, detector: detector2, passed: 7, total: 10)
      end

      it 'aggregates data by target correctly' do
        result = subject.call

        # Check overall structure
        expect(result[:dates].length).to eq(30)
        expect(result[:targets].length).to eq(2)
        expect(result[:scan_summary][:total_reports]).to eq(5)
        expect(result[:scan_summary][:total_tests]).to eq(50) # Sum of all total tests
        expect(result[:scan_summary][:total_passed]).to eq(29) # Sum of all passed tests

        # Check that targets are present
        target_names = result[:targets].map { |t| t[:name] }
        expect(target_names).to include('Target 1', 'Target 2')

        # Check target 1 data
        target1_data = result[:targets].find { |t| t[:name] == 'Target 1' }
        expect(target1_data[:model_info]).to eq('OpenAIGenerator - gpt-3.5-turbo')
        expect(target1_data[:summary][:total_reports]).to eq(2)
        expect(target1_data[:summary][:total_tests]).to eq(30) # 10+10+10
        expect(target1_data[:summary][:total_passed]).to eq(19) # 8+5+6
        expect(target1_data[:summary][:total_failed]).to eq(11) # 30-19
        expect(target1_data[:summary][:success_rate]).to eq(63.3) # 19/30 * 100

        # Check target 2 data
        target2_data = result[:targets].find { |t| t[:name] == 'Target 2' }
        expect(target2_data[:model_info]).to eq('OpenAIGenerator - claude-2')
        expect(target2_data[:summary][:total_reports]).to eq(1)
        expect(target2_data[:summary][:total_tests]).to eq(20) # 10+10
        expect(target2_data[:summary][:total_passed]).to eq(10) # 3+7
        expect(target2_data[:summary][:total_failed]).to eq(10) # 20-10
        expect(target2_data[:summary][:success_rate]).to eq(50.0) # 10/20 * 100

        # Check daily data arrays
        expect(target1_data[:failed_data].length).to eq(30)
        expect(target1_data[:passed_data].length).to eq(30)
        expect(target1_data[:total_data].length).to eq(30)

        # Check detector stats for both targets
        expect(target1_data[:summary][:detector_stats].keys).to include('detector.type1', 'detector.type2')
        expect(target2_data[:summary][:detector_stats].keys).to include('detector.type1', 'detector.type2')
      end

      it 'aggregates detector statistics correctly' do
        result = subject.call

        # Check detector stats in scan summary
        expect(result[:scan_summary][:detector_stats].keys).to include('detector.type1', 'detector.type2')

        detector1_stats = result[:scan_summary][:detector_stats]['detector.type1']
        expect(detector1_stats[:passed]).to eq(17) # 8+6+3
        expect(detector1_stats[:total]).to eq(30) # 10+10+10
        expect(detector1_stats[:failed]).to eq(13) # 30-17

        detector2_stats = result[:scan_summary][:detector_stats]['detector.type2']
        expect(detector2_stats[:passed]).to eq(12) # 5+7
        expect(detector2_stats[:total]).to eq(20) # 10+10
        expect(detector2_stats[:failed]).to eq(8) # 20-12
      end

      it 'correctly formats daily data arrays' do
        result = subject.call

        # Get target data
        target1_data = result[:targets].find { |t| t[:name] == 'Target 1' }

        # Find index of today and 2 days ago
        today_index = 29 # Last day in the 30-day series
        two_days_ago_index = 27 # 29 - 2

        # Check today's data for Target 1
        expect(target1_data[:passed_data][today_index]).to eq(13) # 8+5
        expect(target1_data[:failed_data][today_index]).to eq(7) # 20-13
        expect(target1_data[:total_data][today_index]).to eq(20) # 10+10

        # Check 2 days ago data for Target 1
        expect(target1_data[:passed_data][two_days_ago_index]).to eq(6)
        expect(target1_data[:failed_data][two_days_ago_index]).to eq(4) # 10-6
        expect(target1_data[:total_data][two_days_ago_index]).to eq(10)
      end

      it 'sorts detector stats by total tests' do
        # Create a report with more tests for detector2
        report = create(:report, target: target1, scan: scan, created_at: 1.day.ago)
        create(:detector_result, report: report, detector: detector2, passed: 15, total: 30)

        result = subject.call

        # Check that detector2 (with more total tests) comes first in the sorted hash
        target1_data = result[:targets].find { |t| t[:name] == 'Target 1' }
        detector_stats_keys = target1_data[:summary][:detector_stats].keys
        expect(detector_stats_keys.first).to eq('detector.type2')
        expect(detector_stats_keys.last).to eq('detector.type1')

        # Check scan summary detector stats are also sorted
        scan_detector_keys = result[:scan_summary][:detector_stats].keys
        expect(scan_detector_keys.first).to eq('detector.type2')
        expect(scan_detector_keys.last).to eq('detector.type1')
      end
    end

    context 'with scan filter' do
      let!(:scan1) { create(:complete_scan) }
      let!(:scan2) { create(:complete_scan) }
      let!(:target) { create(:target) }

      before do
        # Create report and detector results for scan1
        report1 = create(:report, target: target, scan: scan1, created_at: Time.zone.today)
        create(:detector_result, report: report1, detector: detector, passed: 8, total: 10)

        # Create report and detector results for scan2
        report2 = create(:report, target: target, scan: scan2, created_at: Time.zone.today)
        create(:detector_result, report: report2, detector: detector, passed: 5, total: 10)
      end

      it 'filters data by scan_id' do
        result = described_class.new(scan_id: scan1.id).call

        expect(result[:scan_summary][:total_reports]).to eq(3)
        expect(result[:scan_summary][:total_tests]).to eq(10)
        expect(result[:scan_summary][:total_passed]).to eq(8)

        # Make sure we only have data for scan1
        target_data = result[:targets].first
        expect(target_data[:summary][:total_tests]).to eq(10)
        expect(target_data[:summary][:total_passed]).to eq(8)
      end
    end

    context 'with data outside the 30-day window' do
      let!(:target) { create(:target) }

      before do
        # Create report within the window
        recent_report = create(:report, target: target, scan: scan, created_at: 5.days.ago)
        create(:detector_result, report: recent_report, detector: detector, passed: 8, total: 10)

        # Create report outside the window (31 days ago)
        old_report = create(:report, target: target, scan: scan, created_at: 31.days.ago)
        create(:detector_result, report: old_report, detector: detector, passed: 5, total: 10)
      end

      it 'only includes data from the last 30 days' do
        result = subject.call

        expect(result[:scan_summary][:total_reports]).to eq(3)
        expect(result[:scan_summary][:total_tests]).to eq(10)
        expect(result[:scan_summary][:total_passed]).to eq(8)

        # Make sure we only count data from the recent report
        target_data = result[:targets].first
        expect(target_data[:summary][:total_tests]).to eq(10)
        expect(target_data[:summary][:total_passed]).to eq(8)
      end
    end

    context 'with zero test cases' do
      let!(:target) { create(:target) }

      before do
        # Create report with zero tests
        report = create(:report, target: target, scan: scan, created_at: Time.zone.today)
        create(:detector_result, report: report, detector: detector, passed: 0, total: 0)
      end

      it 'handles zero division gracefully' do
        result = subject.call

        expect(result[:scan_summary][:total_tests]).to eq(0)
        expect(result[:scan_summary][:total_passed]).to eq(0)
        expect(result[:scan_summary][:success_rate]).to eq(0)

        target_data = result[:targets].first
        expect(target_data[:summary][:success_rate]).to eq(0)
      end
    end
  end
end
