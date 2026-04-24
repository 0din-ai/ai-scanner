# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reports::RunningStats, type: :service do
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let(:target) { create(:target, company: company) }
  let(:scan) { create(:complete_scan, company: company) }
  let(:other_target) { create(:target, company: other_company) }
  let(:other_scan) { create(:complete_scan, company: other_company) }

  before do
    allow_any_instance_of(RunGarakScan).to receive(:call)
    allow_any_instance_of(ToastNotifier).to receive(:call)
    allow(BroadcastRunningStatsJob).to receive(:perform_later)
  end

  describe '.company' do
    it 'counts active parent and variant reports for the requested company' do
      create(:report, target: target, scan: scan, status: :running, company: company)
      create(:report, target: target, scan: scan, status: :starting, company: company)
      parent_report = create(:report, target: target, scan: scan, status: :running, company: company)
      create(:report, target: target, scan: scan, status: :running, parent_report: parent_report, company: company)
      create(:report, target: target, scan: scan, status: :completed, company: company)
      create(:report, target: other_target, scan: other_scan, status: :running, company: other_company)

      stats = described_class.company(company.id)

      expect(stats).to eq(scans: 3, variants: 1, total: 4)
    end

    it 'works when the requested company is the current tenant' do
      create(:report, target: target, scan: scan, status: :running, company: company)
      create(:report, target: other_target, scan: other_scan, status: :running, company: other_company)

      ActsAsTenant.with_tenant(company) do
        expect(described_class.company(company.id)).to eq(scans: 1, variants: 0, total: 1)
      end
    end
  end

  describe '.global' do
    it 'counts active reports across tenants and includes priority parent reports' do
      priority_scan = create(:complete_scan, company: company, priority: true)
      priority_report = create(:report, target: target, scan: priority_scan, status: :running, company: company)
      create(:report, target: target, scan: scan, status: :running, parent_report: priority_report, company: company)
      create(:report, target: other_target, scan: other_scan, status: :starting, company: other_company)
      create(:report, target: target, scan: scan, status: :completed, company: company)

      stats = described_class.global

      expect(stats).to eq(scans: 2, variants: 1, total: 3, priority: 1)
    end

    it 'ignores the current tenant when calculating global stats' do
      create(:report, target: target, scan: scan, status: :running, company: company)
      create(:report, target: other_target, scan: other_scan, status: :running, company: other_company)

      ActsAsTenant.with_tenant(company) do
        expect(described_class.global).to eq(scans: 2, variants: 0, total: 2, priority: 0)
      end
    end
  end

  describe '.write_company' do
    it 'writes the current company stats to the cache' do
      create(:report, target: target, scan: scan, status: :running, company: company)
      allow(Rails.cache).to receive(:write)

      stats = described_class.write_company(company.id)

      expect(stats).to eq(scans: 1, variants: 0, total: 1)
      expect(Rails.cache).to have_received(:write).with(
        "running_scans_stats:#{company.id}",
        stats,
        expires_in: described_class::CACHE_TTL
      )
    end
  end

  describe '.write_global' do
    it 'writes the current global stats to the cache' do
      create(:report, target: target, scan: scan, status: :running, company: company)
      allow(Rails.cache).to receive(:write)

      stats = described_class.write_global

      expect(stats).to eq(scans: 1, variants: 0, total: 1, priority: 0)
      expect(Rails.cache).to have_received(:write).with(
        'running_scans_stats:global',
        stats,
        expires_in: described_class::CACHE_TTL
      )
    end
  end
end
