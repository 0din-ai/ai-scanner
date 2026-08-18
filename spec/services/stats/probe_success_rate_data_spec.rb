require 'rails_helper'

RSpec.describe Stats::ProbeSuccessRateData do
  describe '#call' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:detector) { create(:detector) }
    let(:probe) { create(:probe) }
    let(:report) { create(:report, target: target, scan: scan) }

    describe 'with no filters' do
      subject { described_class.new }

      context 'when no probe results exist' do
        it 'returns no success rate rather than a false 0%' do
          result = subject.call

          expect(result[:success_rate]).to be_nil
          expect(result[:time_range]).to eq("Last 30 Days")
        end
      end

      context 'when probe results exist' do
        before do
          # Create some probe results in the last 30 days
          create(:probe_result,
                report: report,
                probe: probe,
                detector: detector,
                passed: 8,
                total: 10,
                created_at: 1.day.ago)

          create(:probe_result,
                report: report,
                probe: create(:probe),
                detector: detector,
                passed: 12,
                total: 20,
                created_at: 2.days.ago)
        end

        it 'calculates the overall success rate' do
          result = subject.call

          # Expected rate: (8+12)/(10+20) = 20/30 = 66.7%
          expect(result[:success_rate]).to eq(66.7)
          expect(result[:time_range]).to eq("Last 30 Days")
        end
      end

      context 'with results outside the time range' do
        let(:another_probe) { create(:probe) }

        before do
          # Result within time range
          create(:probe_result,
                report: report,
                probe: probe,
                detector: detector,
                passed: 5,
                total: 10,
                created_at: 15.days.ago)

          # Result outside time range (31 days ago)
          create(:probe_result,
                report: report,
                probe: another_probe,
                detector: detector,
                passed: 0,
                total: 10,
                created_at: 31.days.ago)
        end

        it 'only includes results from the last 30 days' do
          result = subject.call

          # Only the result from within the last 30 days is included
          # Expected rate: 5/10 = 50.0%
          expect(result[:success_rate]).to eq(50.0)
        end
      end
    end

    describe 'with probe filter' do
      let(:another_probe) { create(:probe) }
      subject { described_class.new(probe_id: probe.id) }

      before do
        # Create results for our target probe
        create(:probe_result,
              report: report,
              probe: probe,
              detector: detector,
              passed: 7,
              total: 10,
              created_at: 5.days.ago)

        # Create results for another probe (should be filtered out)
        create(:probe_result,
              report: report,
              probe: another_probe,
              detector: detector,
              passed: 0,
              total: 10,
              created_at: 6.days.ago)
      end

      it 'only includes results for the specified probe' do
        result = subject.call

        expect(result[:success_rate]).to eq(70.0) # 7/10 = 70%
      end
    end

    describe 'with target filter' do
      let(:another_target) { create(:target) }
      let(:another_report) { create(:report, target: another_target, scan: scan) }
      subject { described_class.new(target_id: target.id) }

      before do
        # Create results for our target
        create(:probe_result,
              report: report,
              probe: probe,
              detector: detector,
              passed: 6,
              total: 10,
              created_at: 7.days.ago)

        # Create results for another target (should be filtered out)
        create(:probe_result,
              report: another_report,
              probe: probe,
              detector: detector,
              passed: 0,
              total: 10,
              created_at: 8.days.ago)
      end

      it 'only includes results for the specified target' do
        result = subject.call

        expect(result[:success_rate]).to eq(60.0) # 6/10 = 60%
      end
    end

    describe 'with scan filter' do
      let(:another_scan) { create(:complete_scan) }
      let(:another_report) { create(:report, target: target, scan: another_scan) }
      subject { described_class.new(scan_id: scan.id) }

      before do
        # Create results for our scan
        create(:probe_result,
              report: report,
              probe: probe,
              detector: detector,
              passed: 9,
              total: 10,
              created_at: 9.days.ago)

        # Create results for another scan (should be filtered out)
        create(:probe_result,
              report: another_report,
              probe: probe,
              detector: detector,
              passed: 0,
              total: 10,
              created_at: 10.days.ago)
      end

      it 'only includes results for the specified scan' do
        result = subject.call

        expect(result[:success_rate]).to eq(90.0) # 9/10 = 90%
      end
    end

    describe 'with report filter' do
      let(:another_report) { create(:report, target: target, scan: scan) }
      subject { described_class.new(report_id: report.id) }

      before do
        # Create results for our report
        create(:probe_result,
              report: report,
              probe: probe,
              detector: detector,
              passed: 8,
              total: 10,
              created_at: 11.days.ago)

        # Create results for another report (should be filtered out)
        create(:probe_result,
              report: another_report,
              probe: probe,
              detector: detector,
              passed: 0,
              total: 10,
              created_at: 12.days.ago)
      end

      it 'only includes results for the specified report' do
        result = subject.call

        expect(result[:success_rate]).to eq(80.0) # 8/10 = 80%
      end
    end

    describe 'with multiple filters' do
      let(:another_target) { create(:target) }
      let(:another_report) { create(:report, target: another_target, scan: scan) }
      let(:another_probe) { create(:probe) }

      subject { described_class.new(probe_id: probe.id, target_id: target.id) }

      before do
        # Result that matches both filters
        create(:probe_result,
              report: report,
              probe: probe,
              detector: detector,
              passed: 7,
              total: 10,
              created_at: 13.days.ago)

        # Result that only matches the probe filter
        create(:probe_result,
              report: another_report,
              probe: probe,
              detector: detector,
              passed: 0,
              total: 10,
              created_at: 14.days.ago)

        # Result that only matches the target filter
        create(:probe_result,
              report: report,
              probe: another_probe,
              detector: detector,
              passed: 0,
              total: 10,
              created_at: 16.days.ago)
      end

      it 'applies all filters' do
        result = subject.call

        expect(result[:success_rate]).to eq(70.0) # 7/10 = 70%
      end
    end

    describe 'edge cases' do
      context 'when total tests is zero' do
        before do
          create(:probe_result,
                report: report,
                probe: probe,
                detector: detector,
                passed: 0,
                total: 0,
                created_at: 20.days.ago)
        end

        it 'reports no rate rather than a false 0%, matching Reports::AsrFigure' do
          result = described_class.new.call

          expect(result[:success_rate]).to be_nil
        end
      end
    end
  end
end
