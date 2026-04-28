require 'rails_helper'

RSpec.describe Reports::Cleanup do
  let(:target) { create(:target) }
  let(:scan) { create(:complete_scan) }
  let(:report) { create(:report, target: target, scan: scan) }
  let(:service) { described_class.new(report) }

  before do
    # Stub external service calls
    allow_any_instance_of(RunGarakScan).to receive(:call)
    allow_any_instance_of(ToastNotifier).to receive(:call)
  end

  describe '#call' do
    # Note: File cleanup is now handled by Python db_notifier on the same pod
    # where the scan ran. Ruby cleanup only handles database resources.

    context 'when raw_report_data exists' do
      let!(:raw_data) { create(:raw_report_data, report: report) }

      it 'deletes any stale raw_report_data' do
        expect { service.call }.to change { RawReportData.count }.by(-1)
      end

      it 'preserves shared final logs' do
        debug_log = create(:report_debug_log, report: report, logs: 'Final execution logs')

        service.call

        expect(debug_log.reload.logs).to eq('Final execution logs')
      end
    end

    context 'when raw_report_data does not exist' do
      it 'handles missing raw_report_data gracefully' do
        expect { service.call }.not_to raise_error
      end
    end

    context 'with raw_report_data for different reports' do
      let(:other_report) { create(:report, target: target, scan: scan) }
      let!(:raw_data) { create(:raw_report_data, report: report) }
      let!(:other_raw_data) { create(:raw_report_data, report: other_report) }

      it 'only deletes raw_report_data for the specific report' do
        expect(RawReportData.count).to eq(2)

        service.call

        expect(RawReportData.count).to eq(1)
        expect(RawReportData.where(report_id: other_report.id).count).to eq(1)
      end
    end
  end

  describe 'multi-pod deployment' do
    it 'only cleans up database resources (not files)' do
      # In multi-pod deployments, files are on a different pod
      # Ruby cleanup should only handle database resources
      expect(service).not_to respond_to(:delete_config_files)
    end
  end
end
