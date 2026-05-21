require 'rails_helper'

RSpec.describe ReportDecorator, type: :decorator do
  let(:company) { create(:company) }
  let(:target) { create(:target, name: 'Test Target', company: company) }
  let(:scan) { create(:complete_scan, company: company) }
  let(:report) { create(:report, company: company, target: target, scan: scan) }
  let(:decorated_report) { described_class.new(report) }

  describe '#target_name' do
    it 'returns the name of the target' do
      expect(decorated_report.target_name).to eq('Test Target')
    end

    it 'returns the historical target name when the target has been soft-deleted' do
      target.mark_deleted!
      report.reload

      expect(report.target).to be_nil
      expect(described_class.new(report).target_name).to eq('Test Target')
    end
  end

  describe '#probe_results' do
    let!(:probe_result1) { create(:probe_result, report: report, passed: 10) }
    let!(:probe_result2) { create(:probe_result, report: report, passed: 0) }

    it 'returns probe results ordered by passed status' do
      results = decorated_report.probe_results
      expect(results.first.passed).to eq(10)
      expect(results.last.passed).to eq(0)
    end

    it 'includes probe and detector associations' do
      # Create a new instance for this test to avoid memoization issues
      new_report = create(:report, company: company, target: target, scan: scan)
      new_probe = create(:probe, name: 'TestProbe')
      new_detector = create(:detector, name: 'TestDetector')
      create(:probe_result, report: new_report, probe: new_probe, detector: new_detector)

      new_decorated_report = described_class.new(new_report)
      results = new_decorated_report.probe_results

      # Verify that associations are loaded
      expect(results.first.association(:probe).loaded?).to be true
      expect(results.first.association(:detector).loaded?).to be true

      # Verify the associated objects
      expect(results.first.probe.name).to eq('TestProbe')
      expect(results.first.detector.name).to eq('TestDetector')
    end

    it 'memoizes the results' do
      # Call once to memoize
      first_call = decorated_report.probe_results

      # Expect the second call to return the same object
      expect(decorated_report.probe_results).to be(first_call)
    end
  end

  describe '#scan_duration' do
    context 'when start_time and end_time are present' do
      before do
        allow(report).to receive(:start_time).and_return(Time.new(2023, 1, 1, 10, 0, 0))
        allow(report).to receive(:end_time).and_return(Time.new(2023, 1, 1, 10, 30, 0))
      end

      it 'returns the formatted duration' do
        expect(decorated_report.scan_duration).to eq('30 minutes')
      end
    end

    context 'when start_time is missing' do
      before do
        allow(report).to receive(:start_time).and_return(nil)
        allow(report).to receive(:end_time).and_return(Time.new(2023, 1, 1, 10, 30, 0))
      end

      it 'returns N/A' do
        expect(decorated_report.scan_duration).to eq('N/A')
      end
    end

    context 'when end_time is missing' do
      before do
        allow(report).to receive(:start_time).and_return(Time.new(2023, 1, 1, 10, 0, 0))
        allow(report).to receive(:end_time).and_return(nil)
      end

      it 'returns N/A' do
        expect(decorated_report.scan_duration).to eq('N/A')
      end
    end
  end

  describe '#probe_count' do
    context 'when there are probe results' do
      before do
        create_list(:probe_result, 3, report: report)
      end

      it 'returns the count of probe results' do
        expect(decorated_report.probe_count).to eq(3)
      end
    end

    context 'when there are no probe results' do
      it 'returns zero' do
        expect(decorated_report.probe_count).to eq(0)
      end
    end
  end
end
