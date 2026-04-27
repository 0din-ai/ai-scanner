require "rails_helper"

RSpec.describe "Report Processing Flow", type: :integration do
  let(:target) { create(:target) }
  let(:scan) { create(:complete_scan) }
  let(:report) { create(:report, :running, target: target, scan: scan) }
  let!(:probe) { create(:probe, name: "test.TestProbe") }

  let(:valid_jsonl) do
    [
      { entry_type: "init", start_time: "2023-06-01T10:00:00Z" }.to_json,
      { entry_type: "attempt", probe_classname: "test.TestProbe", uuid: "attempt-1",
        prompt: "Test prompt", outputs: [ "Output" ], notes: { score_percentage: 50 } }.to_json,
      { entry_type: "eval", detector: "detector.test_detector", probe: "test.TestProbe",
        passed: 5, total_evaluated: 10 }.to_json,
      { entry_type: "completion", end_time: "2023-06-01T11:00:00Z" }.to_json
    ].join("\n")
  end

  before do
    # Note: Reports::Cleanup no longer has delete_files - file cleanup moved to Python (multi-pod)
    allow_any_instance_of(OutputServers::Dispatcher).to receive(:call)
    allow(ToastNotifier).to receive(:call)
  end

  describe "end-to-end processing" do
    context "when raw_report_data exists with valid JSONL" do
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: valid_jsonl, logs_data: "Log output") }

      it "processes report and cleans up raw_report_data" do
        expect {
          Reports::Process.new(report.id).call
        }.to change { RawReportData.count }.by(-1)
          .and change { ProbeResult.count }.by(1)
          .and change { DetectorResult.count }.by(1)

        report.reload
        expect(report.status).to eq("completed")
        expect(report.logs).to eq("Log output")
        expect(report.start_time).to be_present
        expect(report.end_time).to be_present
      end

      it "marks raw_data as processing before destruction" do
        # Capture the status change before destroy
        processing_status = nil
        allow_any_instance_of(RawReportData).to receive(:mark_processing!).and_wrap_original do |method|
          result = method.call
          processing_status = RawReportData.find_by(report_id: report.id)&.status
          result
        end

        Reports::Process.new(report.id).call
        expect(processing_status).to eq("processing")
      end
    end

    context "when raw_report_data does not exist" do
      it "raises error for Solid Queue retry" do
        expect {
          Reports::Process.new(report.id).call
        }.to raise_error(StandardError, /raw_report_data not found/)
      end

      it "does not change report status" do
        original_status = report.status
        expect {
          Reports::Process.new(report.id).call
        }.to raise_error(StandardError)
        expect(report.reload.status).to eq(original_status)
      end
    end

    context "simulating race condition (job runs before primary commit)" do
      it "retries via Solid Queue when data is missing, then succeeds" do
        # First call - no data yet (simulates job running before primary commit)
        expect {
          Reports::Process.new(report.id).call
        }.to raise_error(StandardError, /raw_report_data not found/)

        # Primary commit happens (data appears after retry delay)
        create(:raw_report_data, report: report, jsonl_data: valid_jsonl)

        # Retry succeeds
        expect {
          Reports::Process.new(report.id).call
        }.to change { RawReportData.count }.by(-1)

        expect(report.reload.status).to eq("completed")
      end
    end

    context "when raw_report_data has invalid JSONL" do
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: "not valid json") }

      it "marks report as failed but does not raise" do
        expect {
          Reports::Process.new(report.id).call
        }.not_to raise_error

        expect(report.reload.status).to eq("failed")
      end

      it "still cleans up raw_report_data" do
        expect {
          Reports::Process.new(report.id).call
        }.to change { RawReportData.count }.by(-1)
      end
    end

    context "when raw_report_data has only whitespace" do
      let!(:raw_data) do
        rd = create(:raw_report_data, report: report)
        rd.update_column(:jsonl_data, "\n\n\n")
        rd
      end

      it "raises error because blank content is treated as not found" do
        expect {
          Reports::Process.new(report.id).call
        }.to raise_error(StandardError, /raw_report_data not found/)
      end
    end
  end

  describe "cleanup integration" do
    context "when stale raw_report_data exists after processing" do
      let!(:raw_data) { create(:raw_report_data, report: report, jsonl_data: valid_jsonl) }

      it "Reports::Cleanup removes any remaining raw_report_data" do
        # Process normally (this deletes raw_data)
        Reports::Process.new(report.id).call
        expect(RawReportData.where(report_id: report.id).count).to eq(0)

        # Create stale data (simulating edge case)
        create(:raw_report_data, report: report, jsonl_data: valid_jsonl)
        expect(RawReportData.where(report_id: report.id).count).to eq(1)

        # Cleanup removes it
        Reports::Cleanup.new(report).call
        expect(RawReportData.where(report_id: report.id).count).to eq(0)
      end
    end
  end
end
