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

    context 'when processing variant probe results' do
      let!(:probe) { create(:probe, name: 'TestProbe') }
      let(:industry) { create(:threat_variant_industry, name: 'Automotive') }
      let(:subindustry) { create(:threat_variant_subindustry, name: 'Autonomous Driving', threat_variant_industry: industry) }
      let!(:variant) { create(:threat_variant, prompt: 'Variant_TAG_Automotive_Autonomous_Driving', probe: probe, threat_variant_subindustry: subindustry) }

      let(:variant_jsonl_content) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: '0din_variants.Variant_TAG_Automotive_Autonomous_Driving', uuid: 'attempt-v1', prompt: 'Variant prompt', outputs: [ 'Variant output' ], notes: { score_percentage: 85 } }.to_json,
          { entry_type: 'eval', detector: 'detector.test_detector', probe: '0din_variants.Variant_TAG_Automotive_Autonomous_Driving', passed: 2, total: 10 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end

      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: variant_jsonl_content) }

      it 'creates probe results linked to the variant' do
        expect { service.call }.to change { ProbeResult.count }.by(1)

        probe_result = ProbeResult.last
        expect(probe_result.probe).to eq(probe)
        expect(probe_result.threat_variant).to eq(variant)
        expect(probe_result.passed).to eq(8) # 10 - 2
        expect(probe_result.total).to eq(10)
        expect(probe_result.max_score).to eq(85)
      end

      it 'completes the report successfully' do
        service.call
        expect(report.status).to eq('completed')
      end

      context 'with shared class names across base and CM probes' do
        let(:cm_probe) { create(:probe, name: 'TestProbeCM') }
        let!(:cm_variant) do
          create(:threat_variant, prompt: 'Variant_TAG_Automotive_Autonomous_Driving',
                 probe: cm_probe, threat_variant_subindustry: subindustry)
        end

        it 'assigns tokens only once to avoid inflating totals' do
          expect { service.call }.to change { ProbeResult.count }.by(2)

          results = report.probe_results.where.not(threat_variant_id: nil).order(:id)
          expect(results.size).to eq(2)

          # First result gets the tokens
          expect(results.first.input_tokens).to be >= 0
          expect(results.first.output_tokens).to be >= 0

          # Second result gets zero tokens (shared classname, single execution)
          expect(results.second.input_tokens).to eq(0)
          expect(results.second.output_tokens).to eq(0)
        end
      end
    end

    context 'when processing unknown variant probe results' do
      let(:unknown_variant_jsonl) do
        [
          { entry_type: 'init', start_time: '2023-06-01T10:00:00Z' }.to_json,
          { entry_type: 'attempt', probe_classname: '0din_variants.Variant_TAG_Unknown_Missing', uuid: 'attempt-v2', prompt: 'Unknown variant', outputs: [ 'Output' ], notes: {} }.to_json,
          { entry_type: 'eval', detector: 'detector.test_detector', probe: '0din_variants.Variant_TAG_Unknown_Missing', passed: 5, total: 5 }.to_json,
          { entry_type: 'completion', end_time: '2023-06-01T11:00:00Z' }.to_json
        ].join("\n")
      end

      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: unknown_variant_jsonl) }

      before do
        allow(Rails.logger).to receive(:warn)
      end

      it 'skips unknown variant probes without creating probe results' do
        expect { service.call }.not_to change { ProbeResult.count }
      end

      it 'marks report as failed when no valid probes processed' do
        service.call
        expect(report.status).to eq('failed')
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

  describe '#resolve_probe' do
    let(:target) { create(:target) }
    let(:scan) { create(:complete_scan) }
    let(:report) { create(:report, target: target, scan: scan) }
    let(:service) { described_class.new(report.id) }

    context 'with a variant probe classname' do
      let(:probe) { create(:probe, name: 'TestProbe') }
      let(:industry) { create(:threat_variant_industry, name: 'Automotive') }
      let(:subindustry) { create(:threat_variant_subindustry, name: 'Autonomous Driving', threat_variant_industry: industry) }
      let!(:variant) { create(:threat_variant, prompt: 'Variant_TAG_Automotive_Autonomous_Driving', probe: probe, threat_variant_subindustry: subindustry) }

      it 'resolves to the correct probe and variant' do
        results = service.send(:resolve_probe, '0din_variants.Variant_TAG_Automotive_Autonomous_Driving')
        expect(results).to be_an(Array)
        expect(results.length).to eq(1)
        expect(results.first[:probe_id]).to eq(probe.id)
        expect(results.first[:variant]).to eq(variant)
        expect(results.first[:skip]).to be_nil
      end

      it 'returns skip when variant is not found' do
        results = service.send(:resolve_probe, '0din_variants.Variant_TAG_Unknown_Missing')
        expect(results.first[:skip]).to be true
        expect(results.first[:probe_id]).to be_nil
      end

      it 'logs a warning for unknown variant probes' do
        allow(Rails.logger).to receive(:warn)
        service.send(:resolve_probe, '0din_variants.Variant_TAG_Unknown_Missing')
        expect(Rails.logger).to have_received(:warn).with(/Unknown variant probe: Variant_TAG_Unknown_Missing/)
      end

      context 'with shared class names across base and CM probes' do
        let(:base_detector) { create(:detector, name: '0din.MitigationBypass') }
        let(:cm_detector) { create(:detector, name: '0din.CrystalMethScore') }
        let(:probe) { create(:probe, name: 'TestProbe', detector: base_detector) }
        let(:cm_probe) { create(:probe, name: 'TestProbeCM', detector: cm_detector) }
        let!(:variant) { create(:threat_variant, prompt: 'Variant_TAG_Automotive_Autonomous_Driving', probe: probe, threat_variant_subindustry: subindustry) }
        let!(:cm_variant) { create(:threat_variant, prompt: 'Variant_TAG_Automotive_Autonomous_Driving', probe: cm_probe, threat_variant_subindustry: subindustry) }

        it 'returns all matching probes when no detector is provided' do
          results = service.send(:resolve_probe, '0din_variants.Variant_TAG_Automotive_Autonomous_Driving')
          expect(results.length).to eq(2)
          probe_ids = results.map { |r| r[:probe_id] }
          expect(probe_ids).to contain_exactly(probe.id, cm_probe.id)
        end

        it 'filters to matching detector when detector_name is provided' do
          results = service.send(:resolve_probe, '0din_variants.Variant_TAG_Automotive_Autonomous_Driving', '0din.MitigationBypass')
          expect(results.length).to eq(1)
          expect(results.first[:probe_id]).to eq(probe.id)
        end

        it 'filters to CM probe when CM detector is provided' do
          results = service.send(:resolve_probe, '0din_variants.Variant_TAG_Automotive_Autonomous_Driving', '0din.CrystalMethScore')
          expect(results.length).to eq(1)
          expect(results.first[:probe_id]).to eq(cm_probe.id)
        end
      end
    end

    context 'with a standard probe classname' do
      let!(:probe) { create(:probe, name: 'TestProbe') }

      it 'resolves by full classname' do
        results = service.send(:resolve_probe, '0din.TestProbe')
        expect(results).to be_an(Array)
        expect(results.first[:probe_id]).to eq(probe.id)
        expect(results.first[:variant]).to be_nil
      end

      it 'returns skip for unknown probes' do
        results = service.send(:resolve_probe, '0din.UnknownProbe')
        expect(results.first[:skip]).to be true
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
