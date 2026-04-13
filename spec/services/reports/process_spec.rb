require 'rails_helper'

RSpec.describe Reports::Process, type: :service do
  describe '#initialize' do
    it 'sets the id attribute and initializes empty data structures' do
      service = described_class.new(123)
      expect(service.id).to eq(123)
      expect(service.instance_variable_get(:@report_data)).to eq({})
      expect(service.instance_variable_get(:@detector_stats)).to eq({})
    end
  end

  describe '#call' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, :running, target: target, scan: scan, uuid: 'test-uuid') }
    let(:service) { described_class.new(report.id) }

    let(:jsonl_content) do
      [
        { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
        { entry_type: 'attempt', probe_classname: '0din.TestProbe', uuid: 'attempt-1', prompt: 'Test prompt', outputs: [ 'Test output' ], notes: { score_percentage: 70 } }.to_json,
        { entry_type: 'eval', detector: 'detector.test_detector', probe: '0din.TestProbe', passed: 3, total: 10 }.to_json,
        { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
      ].join("\n")
    end

    before do
      allow(service).to receive(:report).and_return(report)
      allow_any_instance_of(Reports::Cleanup).to receive(:call)
      allow_any_instance_of(OutputServers::Dispatcher).to receive(:call)
      allow(ToastNotifier).to receive(:call)
    end

    context 'when raw_report_data does not exist' do
      before do
        # Ensure no raw_report_data exists
        RawReportData.where(report_id: report.id).delete_all
      end

      it 'raises an error for Solid Queue to retry' do
        expect { service.call }.to raise_error(StandardError, /raw_report_data not found/)
      end

      it 'does not process the report' do
        expect(service).not_to receive(:process_from_database)
        expect { service.call }.to raise_error(StandardError)
      end
    end

    context 'when processing a report with valid data' do
      let(:logs_content) { 'Database log content' }
      let!(:probe) { create(:probe, name: 'TestProbe') }
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: jsonl_content, logs_data: logs_content) }

      it 'updates report status to processing' do
        expect(report).to receive(:update).with(status: :processing)
        service.call
      end

      it 'processes the report data and creates detector results' do
        expect(Detector).to receive(:find_or_create_by).with(name: 'test_detector').and_call_original
        expect { service.call }.to change { report.detector_results.count }.by(1)
      end

      it 'creates probe results with attempt data' do
        expect { service.call }.to change { ProbeResult.count }.by(1)

        probe_result = ProbeResult.last
        expect(probe_result.probe).to eq(probe)
        expect(probe_result.attempts.first['uuid']).to eq('attempt-1')
        expect(probe_result.max_score).to eq(70)
        expect(probe_result.passed).to eq(7) # 10 - 3
        expect(probe_result.total).to eq(10)
      end

      it 'sets report start and end times and calculates token usage' do
        service.call
        report.reload

        expect(report.start_time).to be_present
        expect(report.end_time).to be_present
        expect(report.status).to eq('completed')
        expect(report.logs).to eq(logs_content)
        expect(report.input_tokens).to be > 0
        expect(report.output_tokens).to be > 0
      end

      it 'calls the cleanup service' do
        expect_any_instance_of(Reports::Cleanup).to receive(:call)
        service.call
      end

      it 'sends data to the output server through dispatcher' do
        expect_any_instance_of(OutputServers::Dispatcher).to receive(:call)
        service.call
      end

      it 'marks raw_data as processing' do
        expect_any_instance_of(RawReportData).to receive(:mark_processing!).and_call_original
        service.call
      end

      it 'destroys raw_data after successful processing' do
        expect { service.call }.to change { RawReportData.count }.by(-1)
      end

      it 'logs successful database processing' do
        allow(Rails.logger).to receive(:info)
        expect(Rails.logger).to receive(:info).with(/Processed from database/).at_least(:once)
        service.call
      end
    end

    context 'when raw_report_data has only whitespace in jsonl_data' do
      # Note: Model validation prevents blank jsonl_data, so we test with
      # valid-looking but non-processable content
      let!(:raw_data) do
        # Create with valid data first, then update to bypass validation
        rd = create(:raw_report_data, report: report)
        rd.update_column(:jsonl_data, "\n\n\n")
        rd
      end

      it 'raises an error because blank jsonl_data is treated as not found' do
        # Whitespace-only content is considered blank, triggering the "not found" error
        expect { service.call }.to raise_error(StandardError, /raw_report_data not found/)
      end
    end

    context 'when processing a report with invalid data' do
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: 'not valid json', logs_data: nil) }

      before do
        allow(Rails.logger).to receive(:error)
        allow(Rails.logger).to receive(:debug)
      end

      it 'handles parsing errors gracefully and marks report as failed' do
        expect { service.call }.not_to raise_error
        expect(report.status).to eq('failed')
      end

      it 'logs the JSON parsing error' do
        expect(Rails.logger).to receive(:error).with(/JSON parse error on line 1/)
        expect(Rails.logger).to receive(:debug).with(/Malformed JSON line content/)
        service.call
      end
    end

    context 'when processing a report with mixed valid and invalid lines' do
      let(:mixed_jsonl_content) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          'entry_{\"entry_type\":',  # Malformed line like in the error
          { entry_type: 'attempt', probe_classname: '0din.TestProbe', uuid: 'attempt-1', prompt: 'Test prompt', outputs: [ 'Test output' ], notes: { score_percentage: 70 } }.to_json,
          '',  # Empty line
          { entry_type: 'eval', detector: 'detector.test_detector', probe: '0din.TestProbe', passed: 3, total: 10 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end

      let!(:probe) { create(:probe, name: 'TestProbe') }
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: mixed_jsonl_content, logs_data: nil) }

      before do
        allow(Rails.logger).to receive(:error)
        allow(Rails.logger).to receive(:debug)
      end

      it 'processes valid lines and skips invalid ones' do
        expect { service.call }.to change { ProbeResult.count }.by(1)
        expect(report.status).to eq('completed')
      end

      it 'logs errors for invalid lines' do
        expect(Rails.logger).to receive(:error).with(/JSON parse error on line 2/)
        service.call
      end
    end

    context 'when entry_type is unknown' do
      let!(:probe) { create(:probe, name: 'TestProbe') }
      let(:unknown_entry_jsonl) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: '0din.TestProbe', uuid: 'attempt-1', prompt: 'Test prompt', outputs: [ 'Test output' ], notes: { score_percentage: 70 } }.to_json,
          { entry_type: 'evil_method', payload: 'should be ignored' }.to_json,
          { entry_type: 'eval', detector: 'detector.test_detector', probe: '0din.TestProbe', passed: 3, total: 10 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: unknown_entry_jsonl, logs_data: nil) }

      it 'ignores the unknown entry_type and processes the rest normally' do
        expect { service.call }.to change { ProbeResult.count }.by(1)
        expect(report.status).to eq('completed')
      end

      it 'does not dispatch to arbitrary private methods' do
        expect(service).not_to receive(:send).with('process_evil_method', anything)
        service.call
      end
    end

    context 'when start_time is invalid' do
      let!(:probe) { create(:probe, name: 'TestProbe') }
      let(:bad_start_time_jsonl) do
        [
          { entry_type: 'init', start_time: 'not-a-date' }.to_json,
          { entry_type: 'attempt', probe_classname: '0din.TestProbe', uuid: 'attempt-1', prompt: 'Test prompt', outputs: [ 'Test output' ], notes: { score_percentage: 70 } }.to_json,
          { entry_type: 'eval', detector: 'detector.test_detector', probe: '0din.TestProbe', passed: 3, total: 10 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: bad_start_time_jsonl, logs_data: nil) }

      it 'logs a warning and leaves start_time nil' do
        allow(Rails.logger).to receive(:warn).and_call_original
        service.call
        report.reload
        expect(report.start_time).to be_nil
        expect(Rails.logger).to have_received(:warn).with(/invalid start_time/i)
      end
    end

    context 'when end_time is invalid' do
      let!(:probe) { create(:probe, name: 'TestProbe') }
      let(:bad_end_time_jsonl) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: '0din.TestProbe', uuid: 'attempt-1', prompt: 'Test prompt', outputs: [ 'Test output' ], notes: { score_percentage: 70 } }.to_json,
          { entry_type: 'eval', detector: 'detector.test_detector', probe: '0din.TestProbe', passed: 3, total: 10 }.to_json,
          { entry_type: 'completion', end_time: 'garbage-time' }.to_json
        ].join("\n")
      end
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: bad_end_time_jsonl, logs_data: nil) }

      it 'logs a warning and leaves end_time nil' do
        allow(Rails.logger).to receive(:warn).and_call_original
        service.call
        report.reload
        expect(report.end_time).to be_nil
        expect(Rails.logger).to have_received(:warn).with(/invalid end_time/i)
      end
    end

    context 'when processing a probe with multiple detectors' do
      let!(:probe) { create(:probe, name: 'TestProbe') }
      let(:multi_detector_jsonl) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: '0din.TestProbe', uuid: 'attempt-1', prompt: 'Test prompt', outputs: [ 'Test output' ], notes: { score_percentage: 85 } }.to_json,
          # First detector eval - has attempts and max_score in report_data
          { entry_type: 'eval', detector: 'detector.0din.CrystalMethScore', probe: '0din.TestProbe', passed: 1, total: 4 }.to_json,
          # Second detector eval - report_data already consumed by first eval
          { entry_type: 'eval', detector: 'detector.0din.MitigationBypass', probe: '0din.TestProbe', passed: 3, total: 4 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: multi_detector_jsonl, logs_data: nil) }

      it 'preserves attempts from the first detector eval' do
        service.call

        probe_result = report.probe_results.find_by(probe: probe)
        expect(probe_result.attempts).to be_present
        expect(probe_result.attempts.first['uuid']).to eq('attempt-1')
      end

      it 'preserves max_score from the first detector eval' do
        service.call

        probe_result = report.probe_results.find_by(probe: probe)
        expect(probe_result.max_score).to eq(85)
      end

      it 'keeps the max passed across detectors and associates the detector that produced it' do
        service.call

        probe_result = report.probe_results.find_by(probe: probe)
        # First eval: inverted passed=3, detector=CrystalMethScore → new max
        # Second eval: inverted passed=1, detector=MitigationBypass → not a new max, retained
        expect(probe_result.passed).to eq(3)
        expect(probe_result.total).to eq(4)
        expect(probe_result.detector.name).to eq('0din.CrystalMethScore')
      end

      it 'creates detector results for both detectors' do
        expect { service.call }.to change { DetectorResult.count }.by(2)

        detector_names = report.detector_results.includes(:detector).map { |dr| dr.detector.name }
        expect(detector_names).to contain_exactly('0din.CrystalMethScore', '0din.MitigationBypass')
      end

      it 'does not double-count tokens across detector evals' do
        service.call

        probe_result = report.probe_results.find_by(probe: probe)
        first_eval_input = probe_result.input_tokens
        first_eval_output = probe_result.output_tokens

        # Re-run the same jsonl via a second pass should not inflate token counts —
        # tokens are only recomputed when fresh attempts arrive on an eval.
        expect(first_eval_input).to be > 0
        expect(probe_result.attempts.size).to eq(1)
        # The second detector eval had attempts_data blank, so input/output tokens
        # come from the first eval only, not additively summed.
        expect(first_eval_input).to eq(TokenEstimator.estimate_from_attempts(probe_result.attempts)[:input_tokens])
        expect(first_eval_output).to eq(TokenEstimator.estimate_from_attempts(probe_result.attempts)[:output_tokens])
      end

      it 'sets any_detector_passed when any eval had successful attacks' do
        service.call

        probe_result = report.probe_results.find_by(probe: probe)
        # First eval inverted passed=3; second inverted passed=1. any detector > 0 → true.
        expect(probe_result.any_detector_passed).to be true
      end
    end

    context 'when first detector is bypassed and last detector fully defends' do
      # Regression guard for the "red vulnerable with 0/N numerator" contradiction.
      # Without max-merge on probe_result.passed, the last detector's passed=0
      # would overwrite the earlier detector's passed=4, producing a self-
      # contradictory display (any_detector_passed=true but passed=0).
      let!(:probe) { create(:probe, name: 'TestProbe') }
      let(:first_bypassed_then_defended_jsonl) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: '0din.TestProbe', uuid: 'attempt-1', prompt: 'Test', outputs: [ 'Test' ], notes: { score_percentage: 90 } }.to_json,
          # First detector: 0 defenses out of 4 → inverted passed=4 (fully bypassed)
          { entry_type: 'eval', detector: 'detector.0din.CrystalMethScore', probe: '0din.TestProbe', passed: 0, total: 4 }.to_json,
          # Second detector: 4 defenses out of 4 → inverted passed=0 (fully defended)
          { entry_type: 'eval', detector: 'detector.0din.MitigationBypass', probe: '0din.TestProbe', passed: 4, total: 4 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: first_bypassed_then_defended_jsonl, logs_data: nil) }

      it 'preserves the max passed so display and signal stay consistent' do
        service.call

        probe_result = report.probe_results.find_by(probe: probe)
        expect(probe_result.passed).to eq(4)
        expect(probe_result.any_detector_passed).to be true
        expect(probe_result.detector.name).to eq('0din.CrystalMethScore')
      end
    end

    context 'when two detectors tie on passed' do
      # Regression guard: strict `>` tie-break keeps the first detector's
      # attribution so detector_id is stable against eval re-ordering.
      let!(:probe) { create(:probe, name: 'TestProbe') }
      let(:tie_jsonl) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: '0din.TestProbe', uuid: 'attempt-1', prompt: 'Test', outputs: [ 'Test' ], notes: {} }.to_json,
          { entry_type: 'eval', detector: 'detector.0din.CrystalMethScore', probe: '0din.TestProbe', passed: 2, total: 4 }.to_json,
          { entry_type: 'eval', detector: 'detector.0din.MitigationBypass', probe: '0din.TestProbe', passed: 2, total: 4 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: tie_jsonl, logs_data: nil) }

      it 'keeps the first detector to reach the max' do
        service.call

        probe_result = report.probe_results.find_by(probe: probe)
        expect(probe_result.passed).to eq(2)
        expect(probe_result.detector.name).to eq('0din.CrystalMethScore')
      end
    end

    context 'when detectors report different totals' do
      # Regression guard: passed/total/detector_id must stay tied to the
      # winning detector so we never produce `passed > total` or inconsistent
      # ASR derivations.
      let!(:probe) { create(:probe, name: 'TestProbe') }
      let(:divergent_totals_jsonl) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: '0din.TestProbe', uuid: 'attempt-1', prompt: 'Test', outputs: [ 'Test' ], notes: {} }.to_json,
          # Winning detector: 1 defense out of 5 → inverted passed=4, total=5
          { entry_type: 'eval', detector: 'detector.0din.CrystalMethScore', probe: '0din.TestProbe', passed: 1, total: 5 }.to_json,
          # Later detector: 2 defenses out of 3 → inverted passed=1, total=3 (must not bleed total=3 in)
          { entry_type: 'eval', detector: 'detector.0din.MitigationBypass', probe: '0din.TestProbe', passed: 2, total: 3 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: divergent_totals_jsonl, logs_data: nil) }

      it 'keeps passed and total tied to the winning detector' do
        service.call

        probe_result = report.probe_results.find_by(probe: probe)
        expect(probe_result.passed).to eq(4)
        expect(probe_result.total).to eq(5)
        expect(probe_result.detector.name).to eq('0din.CrystalMethScore')
        expect(probe_result.passed).to be <= probe_result.total
      end
    end

    context 'when an existing probe_result has null detector_id but non-zero passed' do
      # Regression guard: the new_record? fallback must not regress an existing
      # max. A persisted row with detector_id=nil (data anomaly) and passed=5
      # should not be overwritten by a later, lower-scoring eval just because
      # the detector is unset.
      let!(:probe) { create(:probe, name: 'TestProbe') }
      let!(:existing_detector) { create(:detector, name: 'legacy_detector') }
      let!(:existing_probe_result) do
        report.probe_results.create!(
          probe: probe,
          detector: existing_detector,
          passed: 5,
          total: 10,
          any_detector_passed: true
        ).tap { |pr| pr.update_column(:detector_id, nil) }
      end
      let(:lower_eval_jsonl) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: '0din.TestProbe', uuid: 'attempt-1', prompt: 'Test', outputs: [ 'Test' ], notes: {} }.to_json,
          # Lower passed than the persisted max: 7 defenses out of 10 → inverted passed=3
          { entry_type: 'eval', detector: 'detector.test_detector', probe: '0din.TestProbe', passed: 7, total: 10 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: lower_eval_jsonl, logs_data: nil) }

      it 'preserves the persisted max instead of overwriting it' do
        service.call

        existing_probe_result.reload
        expect(existing_probe_result.passed).to eq(5)
        expect(existing_probe_result.total).to eq(10)
      end
    end

    context 'when probe classname is a dotted name that falls back to last segment' do
      # The runtime may emit classnames like "dan.DAN_Jailbreak" where the Probe row
      # was persisted under just "DAN_Jailbreak". The resolver must fall back.
      let!(:probe) { create(:probe, name: 'DAN_Jailbreak') }
      let(:dotted_jsonl) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: 'dan.DAN_Jailbreak', uuid: 'attempt-1', prompt: 'Test', outputs: [ 'Test' ], notes: { score_percentage: 50 } }.to_json,
          { entry_type: 'eval', detector: 'detector.test_detector', probe: 'dan.DAN_Jailbreak', passed: 2, total: 5 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: dotted_jsonl, logs_data: nil) }

      it 'resolves the probe via last-segment fallback' do
        expect { service.call }.to change { ProbeResult.count }.by(1)
        expect(ProbeResult.last.probe).to eq(probe)
      end
    end

    context 'when probe classname is not found in database' do
      let(:unknown_probe_jsonl) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: '0din.NonExistentProbe', uuid: 'attempt-1', prompt: 'Test prompt', outputs: [ 'Test output' ], notes: {} }.to_json,
          { entry_type: 'eval', detector: 'detector.test_detector', probe: '0din.NonExistentProbe', passed: 3, total: 10 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: unknown_probe_jsonl, logs_data: nil) }

      it 'does not create a probe result' do
        expect { service.call }.not_to change { ProbeResult.count }
      end

      it 'logs a warning for the unknown probe' do
        allow(Rails.logger).to receive(:warn)
        service.call
        expect(Rails.logger).to have_received(:warn).with(/Unknown probe classname: 0din.NonExistentProbe/)
      end

      it 'marks the report as failed when no probe results were created' do
        service.call
        expect(report.status).to eq('failed')
      end
    end

    context 'when processing garak 0.14.0 format with total_evaluated' do
      let(:logs_content) { 'Garak 0.14.0 log content' }
      let!(:probe) { create(:probe, name: 'dan.DAN_Jailbreak') }
      let(:garak_014_jsonl) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: 'dan.DAN_Jailbreak', uuid: 'attempt-1', prompt: 'Test prompt', outputs: [ 'Test output' ], notes: {} }.to_json,
          # Garak 0.14.0 uses total_evaluated instead of total
          { entry_type: 'eval', detector: 'detector.dan.DANJailbreak', probe: 'dan.DAN_Jailbreak', passed: 5, total_evaluated: 5 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: garak_014_jsonl, logs_data: logs_content) }

      it 'correctly parses total_evaluated field' do
        expect { service.call }.to change { ProbeResult.count }.by(1)

        probe_result = ProbeResult.last
        expect(probe_result.total).to eq(5)
        expect(probe_result.passed).to eq(0) # 5 - 5 = 0 attacks succeeded
      end

      it 'creates detector results with correct values' do
        expect { service.call }.to change { DetectorResult.count }.by(1)

        detector_result = DetectorResult.last
        expect(detector_result.total).to eq(5)
        expect(detector_result.passed).to eq(0)
      end
    end

    context 'when processing variant report' do
      let(:probe) { create(:probe, name: 'TestProbe') }
      let(:industry) { create(:threat_variant_industry) }
      let(:subindustry) { create(:threat_variant_subindustry, threat_variant_industry: industry) }
      let!(:threat_variant) { create(:threat_variant, probe: probe, threat_variant_subindustry: subindustry, prompt: 'Variant_TEST_001') }

      let(:variant_scan) do
        s = build(:complete_scan)
        s.threat_variant_subindustries << subindustry
        s.save!(validate: false)
        s
      end

      let(:parent_report) { create(:report, target: target, scan: variant_scan) }
      let(:child_report) { create(:report, :running, target: target, scan: variant_scan, parent_report: parent_report, uuid: 'variant-test-uuid') }
      let(:variant_service) { described_class.new(child_report.id) }

      let(:variant_jsonl_content) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: '0din_variants.Variant_TEST_001', uuid: 'attempt-1', prompt: 'Test prompt', outputs: [ 'Test output' ], notes: { score_percentage: 70 } }.to_json,
          { entry_type: 'eval', detector: 'detector.test_detector', probe: '0din_variants.Variant_TEST_001', passed: 3, total: 10 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end

      let!(:variant_raw_data) { create(:raw_report_data, report: child_report, jsonl_data: variant_jsonl_content, logs_data: 'Variant logs') }

      before do
        child_report.variant_probes << probe
      end

      it 'creates probe results with threat_variant_id' do
        expect { variant_service.call }.to change { ProbeResult.count }.by(1)

        probe_result = ProbeResult.last
        expect(probe_result.threat_variant_id).to eq(threat_variant.id)
        expect(probe_result.threat_variant).to eq(threat_variant)
      end

      it 'looks up variant from probe classname' do
        variant_service.call

        probe_result = ProbeResult.last
        expect(probe_result.probe).to eq(probe)
        expect(probe_result.threat_variant.prompt).to eq('Variant_TEST_001')
      end

      it 'handles unknown variant prompt gracefully' do
        bad_content = [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: '0din_variants.Variant_NONEXISTENT', uuid: 'attempt-1', prompt: 'Test', outputs: [ 'Test' ], notes: { score_percentage: 70 } }.to_json,
          { entry_type: 'eval', detector: 'detector.test_detector', probe: '0din_variants.Variant_NONEXISTENT', passed: 3, total: 10 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")

        variant_raw_data.update!(jsonl_data: bad_content)

        allow(Rails.logger).to receive(:warn)
        expect { variant_service.call }.not_to change { ProbeResult.count }
        expect(Rails.logger).to have_received(:warn).with(/Unknown variant probe: Variant_NONEXISTENT/)
      end

      it 'scopes variant lookup to report.variant_probes when present' do
        # A ThreatVariant with the same prompt but tied to a different probe
        # must not be selected when variant_probes constrains the search.
        other_probe = create(:probe, name: 'OtherProbe')
        create(:threat_variant, probe: other_probe, threat_variant_subindustry: subindustry, prompt: 'Variant_TEST_001')

        variant_service.call

        probe_result = ProbeResult.last
        expect(probe_result.probe).to eq(probe)
        expect(probe_result.threat_variant).to eq(threat_variant)
      end

      it 'associates correct variant with probe result' do
        variant_service.call

        probe_result = ProbeResult.last
        expect(probe_result.attempts.first['uuid']).to eq('attempt-1')
        expect(probe_result.threat_variant.threat_variant_subindustry).to eq(subindustry)
        expect(probe_result.passed).to eq(7) # 10 - 3
        expect(probe_result.total).to eq(10)
      end
    end

    context 'idempotent processing for resumed scans' do
      let!(:probe) { create(:probe, name: 'TestProbe') }
      let!(:detector) { create(:detector, name: 'test_detector') }

      let(:jsonl_content) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: '0din.TestProbe', uuid: 'attempt-1', prompt: 'Test', outputs: [ 'Out' ], notes: { score_percentage: 70 } }.to_json,
          { entry_type: 'eval', detector: 'detector.test_detector', probe: '0din.TestProbe', passed: 3, total: 10 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end

      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: jsonl_content) }

      before do
        allow(service).to receive(:report).and_return(report)
        allow_any_instance_of(Reports::Cleanup).to receive(:call)
        allow_any_instance_of(OutputServers::Dispatcher).to receive(:call)
        allow(ToastNotifier).to receive(:call)
      end

      describe '#save_detector_results' do
        it 'upserts when detector_result already exists' do
          # Create existing detector_result from a previous run
          report.detector_results.create!(detector: detector, passed: 5, total: 8, max_score: 50)

          # Processing should overwrite (not fail) on the existing record
          expect { service.call }.not_to raise_error
          expect(report.detector_results.count).to eq(1)

          dr = report.detector_results.first
          expect(dr.passed).to eq(7) # 10 - 3 from JSONL
          expect(dr.total).to eq(10)
        end
      end

      describe '#process_init' do
        it 'preserves original start_time on resumed scan' do
          original_time = Time.parse('2023-05-01T09:00:00Z')
          report.update!(start_time: original_time)

          service.call

          report.reload
          expect(report.start_time).to eq(original_time)
        end

        it 'sets start_time when not previously set' do
          report.update_column(:start_time, nil)

          service.call

          report.reload
          expect(report.start_time).to be_present
        end
      end

      describe 'resumed scan with partial probe data in prefix' do
        let!(:probe_a) { create(:probe, name: 'ProbeA') }
        let!(:probe_b) { create(:probe, name: 'ProbeB') }

        # Override parent jsonl_content so parent's let!(:raw_data) uses this
        let(:jsonl_content) do
          [
            # Prefix from first run
            { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
            { entry_type: 'attempt', probe_classname: '0din.ProbeA', uuid: 'a1', prompt: 'p', outputs: [ 'o' ], notes: {} }.to_json,
            { entry_type: 'eval', detector: 'detector.d1', probe: '0din.ProbeA', passed: 2, total: 5 }.to_json,
            { entry_type: 'attempt', probe_classname: '0din.ProbeB', uuid: 'b1-old', prompt: 'p', outputs: [ 'o' ], notes: { score_percentage: 50 } }.to_json,
            # Second run (garak restarted, re-runs ProbeB)
            { entry_type: 'init', start_time: '2023-06-01T12:00:00Z' }.to_json,
            { entry_type: 'attempt', probe_classname: '0din.ProbeB', uuid: 'b1-new', prompt: 'p', outputs: [ 'o' ], notes: { score_percentage: 80 } }.to_json,
            { entry_type: 'attempt', probe_classname: '0din.ProbeB', uuid: 'b2-new', prompt: 'p', outputs: [ 'o' ], notes: { score_percentage: 90 } }.to_json,
            { entry_type: 'eval', detector: 'detector.d1', probe: '0din.ProbeB', passed: 1, total: 5 }.to_json,
            { entry_type: 'completion', end_time: '2023-06-01T13:00:00Z' }.to_json
          ].join("\n")
        end

        before do
          report.update!(start_time: Time.parse('2023-06-01T10:00:00Z'))
        end

        it 'discards stale partial attempts from previous run' do
          service.call

          probe_b_result = report.probe_results.find_by(probe: probe_b)
          expect(probe_b_result.attempts.length).to eq(2)
          expect(probe_b_result.attempts.map { |a| a['uuid'] }).to eq(%w[b1-new b2-new])
        end

        it 'preserves completed probe data from prefix' do
          service.call

          probe_a_result = report.probe_results.find_by(probe: probe_a)
          expect(probe_a_result.attempts.length).to eq(1)
          expect(probe_a_result.attempts.first['uuid']).to eq('a1')
        end
      end
    end

    context 'when updating target token rate' do
      let!(:probe) { create(:probe, name: 'TestProbe') }
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: jsonl_content, logs_data: 'Test logs') }

      before do
        # Set up report with timing and output tokens
        report.update!(
          start_time: 10.seconds.ago,
          end_time: Time.current,
          status: :running
        )
      end

      it 'calls update_target_token_rate after processing' do
        expect(service).to receive(:update_target_token_rate)
        service.call
      end
    end
  end

  describe '#update_target_token_rate' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan, status: :completed) }
    let(:service) { described_class.new(report.id) }
    let(:detector) { create(:detector) }
    let(:probe) { create(:probe) }

    before do
      allow(service).to receive(:report).and_return(report)
    end

    context 'when report is not completed' do
      before do
        report.update!(status: :running)
      end

      it 'does not update target token rate' do
        expect(target).not_to receive(:update)
        service.send(:update_target_token_rate)
      end
    end

    context 'when target is webchat' do
      let(:target) { create(:target, :webchat) }

      before do
        report.update!(status: :completed, start_time: 10.seconds.ago, end_time: Time.current)
      end

      it 'does not update target token rate' do
        expect(target).not_to receive(:update)
        service.send(:update_target_token_rate)
      end
    end

    context 'when report has no start_time' do
      before do
        report.update!(status: :completed, start_time: nil, end_time: Time.current)
      end

      it 'does not update target token rate' do
        expect(target).not_to receive(:update)
        service.send(:update_target_token_rate)
      end
    end

    context 'when report has no end_time' do
      before do
        report.update!(status: :completed, start_time: 10.seconds.ago, end_time: nil)
      end

      it 'does not update target token rate' do
        expect(target).not_to receive(:update)
        service.send(:update_target_token_rate)
      end
    end

    context 'when duration is zero or negative' do
      before do
        time = Time.current
        report.update!(status: :completed, start_time: time, end_time: time)
      end

      it 'does not update target token rate' do
        expect(target).not_to receive(:update)
        service.send(:update_target_token_rate)
      end
    end

    context 'when report has no output tokens' do
      before do
        report.update!(status: :completed, start_time: 10.seconds.ago, end_time: Time.current)
        # No probe_results, so output_tokens will be 0
      end

      it 'does not update target token rate' do
        expect(target).not_to receive(:update)
        service.send(:update_target_token_rate)
      end
    end

    context 'when all conditions are met for rate calculation' do
      before do
        report.update!(status: :completed, start_time: 10.seconds.ago, end_time: Time.current)
        # Create probe result with output tokens
        create(:probe_result, report: report, probe: probe, detector: detector, output_tokens: 500)
      end

      context 'when target has no existing rate' do
        it 'sets initial tokens_per_second' do
          service.send(:update_target_token_rate)

          target.reload
          expect(target.tokens_per_second).to be_present
          expect(target.tokens_per_second).to be > 0
          # 500 tokens / ~10 seconds = ~50 tok/s
          expect(target.tokens_per_second).to be_within(20).of(50)
        end

        it 'sets tokens_per_second_sample_count to 1' do
          service.send(:update_target_token_rate)

          target.reload
          expect(target.tokens_per_second_sample_count).to eq(1)
        end
      end

      context 'when target already has a rate (weighted average)' do
        before do
          target.update!(tokens_per_second: 40.0, tokens_per_second_sample_count: 2)
        end

        it 'calculates weighted average for new rate' do
          service.send(:update_target_token_rate)

          target.reload
          # Old rate: 40.0, old count: 2
          # New measured rate: ~50 tok/s (500 tokens / 10 seconds)
          # Weighted: (40.0 * 2 + 50) / 3 = 130 / 3 = ~43.3
          expect(target.tokens_per_second_sample_count).to eq(3)
          # Allow some variance due to timing
          expect(target.tokens_per_second).to be_within(10).of(43)
        end

        it 'increments sample count' do
          initial_count = target.tokens_per_second_sample_count

          service.send(:update_target_token_rate)

          target.reload
          expect(target.tokens_per_second_sample_count).to eq(initial_count + 1)
        end
      end

      context 'with precise timing calculation' do
        before do
          # Use precise timing for predictable test
          start_time = Time.current - 20.seconds
          end_time = Time.current
          report.update!(status: :completed, start_time: start_time, end_time: end_time)
          report.probe_results.destroy_all
          create(:probe_result, report: report, probe: probe, detector: detector, output_tokens: 1000)
        end

        it 'calculates rate based on output tokens and duration' do
          service.send(:update_target_token_rate)

          target.reload
          # 1000 tokens / 20 seconds = 50 tok/s
          expect(target.tokens_per_second).to be_within(5).of(50)
        end

        it 'rounds rate to 2 decimal places' do
          service.send(:update_target_token_rate)

          target.reload
          rate_string = target.tokens_per_second.to_s
          decimal_part = rate_string.split('.').last
          expect(decimal_part.length).to be <= 2
        end
      end
    end
  end
end
