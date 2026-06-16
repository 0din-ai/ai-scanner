require 'rails_helper'

RSpec.describe Stats::LastFiveScansData, type: :service do
  describe '#call' do
    let(:company) { create(:company) }

    before do
      ActsAsTenant.current_tenant = company
      # Stub service calls that might be triggered
      allow_any_instance_of(RunGarakScan).to receive(:call)
      allow_any_instance_of(ToastNotifier).to receive(:call)
    end

    def scan_with_asr(name:, asr:, created_at:)
      scan = create(:complete_scan, company: company, name: name, created_at: created_at)
      scan.update_column(:avg_successful_attacks, asr) unless asr.nil?
      scan
    end

    context 'with more than five scans' do
      before do
        scan_with_asr(name: 'Scan A', asr: 10, created_at: 6.days.ago)
        scan_with_asr(name: 'Scan B', asr: 20, created_at: 5.days.ago)
        scan_with_asr(name: 'Scan C', asr: 30, created_at: 4.days.ago)
        scan_with_asr(name: 'Scan D', asr: 40, created_at: 3.days.ago)
        scan_with_asr(name: 'Scan E', asr: 50, created_at: 2.days.ago)
        scan_with_asr(name: 'Scan F', asr: 60, created_at: 1.day.ago)
      end

      it 'returns the five most recent scans, newest first' do
        result = described_class.new.call

        expect(result.length).to eq(5)
        expect(result.map { |r| r[:scan_name] }).to eq([ 'Scan F', 'Scan E', 'Scan D', 'Scan C', 'Scan B' ])
        expect(result.map { |r| r[:asr] }).to eq([ 60, 50, 40, 30, 20 ])
        expect(result.first[:scan_id]).to be_present
      end
    end

    context 'when a scan has no computed ASR' do
      before { scan_with_asr(name: 'No ASR', asr: nil, created_at: 1.day.ago) }

      it 'reports 0' do
        result = described_class.new.call
        expect(result).to eq([ { scan_name: 'No ASR', scan_id: Scan.last.id, asr: 0 } ])
      end
    end

    context 'rounding' do
      before { scan_with_asr(name: 'Fractional', asr: 62.4, created_at: 1.day.ago) }

      it 'rounds ASR to an integer' do
        expect(described_class.new.call.first[:asr]).to eq(62)
      end
    end

    context 'tenant isolation' do
      before do
        scan_with_asr(name: 'Mine', asr: 25, created_at: 1.day.ago)
        other = create(:company)
        ActsAsTenant.with_tenant(other) do
          s = create(:complete_scan, company: other, name: 'Theirs', created_at: 1.day.ago)
          s.update_column(:avg_successful_attacks, 80)
        end
      end

      it 'only returns the current tenant scans' do
        result = described_class.new.call
        expect(result.map { |r| r[:scan_name] }).to eq([ 'Mine' ])
      end
    end
  end
end
