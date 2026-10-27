# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BroadcastRunningStatsJob, type: :job do
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let(:target) { create(:target, company: company) }
  let(:scan) { create(:complete_scan, company: company) }

  before do
    allow_any_instance_of(RunGarakScan).to receive(:call)
    allow_any_instance_of(ToastNotifier).to receive(:call)
    # Mock Turbo broadcast to avoid rendering partial in tests
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  describe '#perform' do
    it 'calculates stats for specific company only' do
      # Create reports for both companies
      create(:report, target: target, scan: scan, status: :running, company: company)
      other_target = create(:target, company: other_company)
      other_scan = create(:complete_scan, company: other_company)
      create(:report, target: other_target, scan: other_scan, status: :running, company: other_company)

      job = described_class.new
      stats = job.send(:calculate_company_stats, company.id)

      expect(stats[:scans]).to eq(1)
      expect(stats[:total]).to eq(1)
    end

    it 'writes company-scoped stats to cache' do
      allow(Rails.cache).to receive(:write).and_call_original

      described_class.new.perform(company.id)

      expect(Rails.cache).to have_received(:write).with(
        "running_scans_stats:#{company.id}",
        hash_including(:scans, :variants, :total),
        expires_in: 1.hour
      )
    end

    it 'broadcasts to company-specific stream' do
      described_class.new.perform(company.id)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).with(
        "system-status:company_#{company.id}",
        target: "system-status-company",
        partial: "application/system_status_company",
        locals: { stats: hash_including(:scans, :variants, :total) }
      )
    end

    it 'also broadcasts global stats' do
      described_class.new.perform(company.id)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).with(
        "system-status:global",
        target: "system-status-global",
        partial: "application/system_status_global",
        locals: { stats: hash_including(:scans, :variants, :total) }
      )
    end

    context 'stats calculation' do
      it 'distinguishes scans from variants' do
        parent_report = create(:report, target: target, scan: scan, status: :running, company: company)
        create(:report, target: target, scan: scan, status: :running, parent_report: parent_report, company: company)

        job = described_class.new
        stats = job.send(:calculate_company_stats, company.id)

        expect(stats[:scans]).to eq(1)
        expect(stats[:variants]).to eq(1)
        expect(stats[:total]).to eq(2)
      end

      it 'returns zero counts when no active reports' do
        create(:report, target: target, scan: scan, status: :completed, company: company)

        job = described_class.new
        stats = job.send(:calculate_company_stats, company.id)

        expect(stats[:scans]).to eq(0)
        expect(stats[:variants]).to eq(0)
        expect(stats[:total]).to eq(0)
      end

      it 'calculates global stats across all companies' do
        create(:report, target: target, scan: scan, status: :running, company: company)
        other_target = create(:target, company: other_company)
        other_scan = create(:complete_scan, company: other_company)
        create(:report, target: other_target, scan: other_scan, status: :running, company: other_company)

        job = described_class.new
        stats = job.send(:calculate_global_stats)

        expect(stats[:scans]).to eq(2)
        expect(stats[:total]).to eq(2)
      end

      it 'calculates global stats even when tenant is set' do
        # Create reports for multiple companies
        create(:report, target: target, scan: scan, status: :running, company: company)
        other_target = create(:target, company: other_company)
        other_scan = create(:complete_scan, company: other_company)
        create(:report, target: other_target, scan: other_scan, status: :running, company: other_company)

        # Set current tenant to one company
        ActsAsTenant.with_tenant(company) do
          job = described_class.new
          stats = job.send(:calculate_global_stats)

          # Should still see reports from BOTH companies due to without_tenant wrapper
          expect(stats[:scans]).to eq(2)
          expect(stats[:total]).to eq(2)
        end
      end

      it 'includes priority count in global stats' do
        priority_scan = create(:complete_scan, company: company, priority: true)
        create(:report, target: target, scan: priority_scan, status: :running, company: company)

        other_target = create(:target, company: other_company)
        other_scan = create(:complete_scan, company: other_company, priority: false)
        create(:report, target: other_target, scan: other_scan, status: :running, company: other_company)

        job = described_class.new
        stats = job.send(:calculate_global_stats)

        expect(stats[:scans]).to eq(2)
        expect(stats[:priority]).to eq(1)
        expect(stats[:total]).to eq(2)
      end
    end
  end

  describe 'queue configuration' do
    it 'uses default queue' do
      expect(described_class.new.queue_name).to eq('default')
    end
  end

  describe 'concurrency configuration' do
    it 'uses company_id in concurrency key' do
      # The job class should have the limits_concurrency configuration with company-specific key
      expect(described_class.concurrency_key).to be_present
    end
  end

  describe 'cache keys and stream names' do
    it 'generates correct cache key for company' do
      job = described_class.new
      expect(job.send(:cache_key_for, 123)).to eq("running_scans_stats:123")
    end

    it 'generates correct cache key for global' do
      job = described_class.new
      expect(job.send(:cache_key_for, :global)).to eq("running_scans_stats:global")
    end

    it 'generates correct stream name for company' do
      job = described_class.new
      expect(job.send(:stream_name_for, 123)).to eq("system-status:company_123")
    end

    it 'generates correct stream name for global' do
      job = described_class.new
      expect(job.send(:stream_name_for, :global)).to eq("system-status:global")
    end
  end
end
