require 'rails_helper'

RSpec.describe Stats::DetectorActivityData do
  describe '#call' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan) }

    let(:detector1) { create(:detector, name: '0din.type1') }
    let(:detector2) { create(:detector, name: '0din.type2') }
    let(:detector3) { create(:detector, name: '0din.type3') }

    describe 'with no filters' do
      subject { described_class.new }

      context 'when no detector results exist' do
        it 'returns empty arrays' do
          result = subject.call

          expect(result[:detector_names]).to eq([])
          expect(result[:test_counts]).to eq([])
          expect(result[:passed_counts]).to eq([])
          expect(result[:time_range]).to eq("Last 30 Days")
        end
      end

      context 'when detector results exist' do
        before do
          create(:detector_result, report: report, detector: detector1, total: 100, passed: 80)
          create(:detector_result, report: report, detector: detector2, total: 50, passed: 30)
          create(:detector_result, report: report, detector: detector3, total: 75, passed: 45)

          old_report = create(:report, target: target, scan: scan, created_at: 35.days.ago)
          create(:detector_result, report: old_report, detector: detector1, total: 200, passed: 150)

          allow(I18n).to receive(:t).with("detectors.names.type1", default: "type1").and_return("Type One")
          allow(I18n).to receive(:t).with("detectors.names.type2", default: "type2").and_return("Type Two")
          allow(I18n).to receive(:t).with("detectors.names.type3", default: "type3").and_return("Type Three")
        end

        it 'returns detector data ordered by total tests' do
          result = subject.call

          expect(result[:detector_names]).to eq([ "Type One", "Type Three", "Type Two" ])
          expect(result[:test_counts]).to eq([ 100, 75, 50 ])
          expect(result[:passed_counts]).to eq([ 80, 45, 30 ])
        end

        it 'only includes results from the last 30 days' do
          result = subject.call
        end
      end
    end

    describe 'with target filter' do
      let(:another_target) { create(:target) }
      let(:another_report) { create(:report, target: another_target, scan: scan) }
      subject { described_class.new(target_id: target.id) }

      before do
        create(:detector_result, report: report, detector: detector1, total: 100, passed: 80)

        create(:detector_result, report: another_report, detector: detector1, total: 50, passed: 30)

        allow(I18n).to receive(:t).with("detectors.names.type1", default: "type1").and_return("Type One")
      end

      it 'only includes results for the specified target' do
        result = subject.call

        expect(result[:test_counts]).to eq([ 100 ])
        expect(result[:passed_counts]).to eq([ 80 ])
      end
    end

    describe 'with scan filter' do
      let(:another_scan) { create(:complete_scan) }
      let(:another_report) { create(:report, target: target, scan: another_scan) }
      subject { described_class.new(scan_id: scan.id) }

      before do
        create(:detector_result, report: report, detector: detector1, total: 100, passed: 80)

        create(:detector_result, report: another_report, detector: detector1, total: 50, passed: 30)

        allow(I18n).to receive(:t).with("detectors.names.type1", default: "type1").and_return("Type One")
      end

      it 'only includes results for the specified scan' do
        result = subject.call

        expect(result[:test_counts]).to eq([ 100 ])
        expect(result[:passed_counts]).to eq([ 80 ])
      end
    end

    describe 'with report filter' do
      let(:another_report) { create(:report, target: target, scan: scan) }
      subject { described_class.new(report_id: report.id) }

      before do
        create(:detector_result, report: report, detector: detector1, total: 100, passed: 80)

        create(:detector_result, report: another_report, detector: detector1, total: 50, passed: 30)

        allow(I18n).to receive(:t).with("detectors.names.type1", default: "type1").and_return("Type One")
      end

      it 'only includes results for the specified report' do
        result = subject.call

        expect(result[:test_counts]).to eq([ 100 ])
        expect(result[:passed_counts]).to eq([ 80 ])
      end
    end

    describe 'with multiple filters' do
      let(:another_target) { create(:target) }
      let(:another_scan) { create(:complete_scan) }
      let(:another_report) { create(:report, target: another_target, scan: another_scan) }

      subject { described_class.new(target_id: target.id, scan_id: scan.id) }

      before do
        create(:detector_result, report: report, detector: detector1, total: 100, passed: 80)

        create(:detector_result,
               report: create(:report, target: target, scan: another_scan),
               detector: detector1,
               total: 50,
               passed: 30)

        allow(I18n).to receive(:t).with("detectors.names.type1", default: "type1").and_return("Type One")
      end

      it 'applies all filters' do
        result = subject.call

        expect(result[:test_counts]).to eq([ 100 ])
        expect(result[:passed_counts]).to eq([ 80 ])
      end
    end

    describe 'i18n handling' do
      subject { described_class.new }

      before do
        create(:detector_result, report: report, detector: detector1, total: 100, passed: 80)
      end

      it 'uses i18n translations when available' do
        allow(I18n).to receive(:t).with("detectors.names.type1", default: "type1").and_return("Translated Type One")

        result = subject.call
        expect(result[:detector_names]).to eq([ "Translated Type One" ])
      end

      it 'falls back to the short name when translation is not available' do
        allow(I18n).to receive(:t).with("detectors.names.type1", default: "type1").and_return("type1")

        result = subject.call
        expect(result[:detector_names]).to eq([ "type1" ])
      end
    end

    describe 'community collapsing' do
      subject { described_class.new }

      context 'with multiple community (garak) detectors' do
        let(:garak1) { create(:detector, name: 'dan.DAN') }
        let(:garak2) { create(:detector, name: 'ansiescape.Escaped') }

        before do
          create(:detector_result, report: report, detector: garak1, total: 60, passed: 40)
          create(:detector_result, report: report, detector: garak2, total: 30, passed: 10)
        end

        it 'collapses them into a single "Community" spoke with summed counts' do
          result = subject.call

          expect(result[:detector_names]).to eq([ "Community" ])
          expect(result[:test_counts]).to eq([ 90 ])
          expect(result[:passed_counts]).to eq([ 50 ])
        end
      end

      context 'with a mix of 0din and community detectors' do
        let(:odin) { create(:detector, name: '0din.MitigationBypass') }
        let(:garak1) { create(:detector, name: 'dan.DAN') }
        let(:garak2) { create(:detector, name: 'continuation.Continuation') }

        before do
          create(:detector_result, report: report, detector: odin, total: 100, passed: 90)
          create(:detector_result, report: report, detector: garak1, total: 40, passed: 20)
          create(:detector_result, report: report, detector: garak2, total: 35, passed: 15)
          allow(I18n).to receive(:t)
            .with("detectors.names.MitigationBypass", default: "MitigationBypass")
            .and_return("Generic Mitigation Bypass Checks")
        end

        it 'keeps 0din individual and collapses community, ordered by total DESC' do
          result = subject.call

          expect(result[:detector_names]).to eq([ "Generic Mitigation Bypass Checks", "Community" ])
          expect(result[:test_counts]).to eq([ 100, 75 ])
          expect(result[:passed_counts]).to eq([ 90, 35 ])
        end
      end
    end
  end
end
