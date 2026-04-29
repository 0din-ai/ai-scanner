# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ReportPolicy do
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let(:user) { create(:user, current_company: company) }
  let(:report) { ActsAsTenant.with_tenant(company) { create(:report, company: company) } }

  describe 'inheritance' do
    it 'inherits from TenantScopedPolicy' do
      expect(described_class.superclass).to eq(TenantScopedPolicy)
    end
  end

  describe 'inherited permissions from TenantScopedPolicy' do
    subject { described_class.new(user, report) }

    it { is_expected.to be_index }
    it { is_expected.to be_show }
    it { is_expected.to be_create }
    it { is_expected.to be_update }
    it { is_expected.to be_destroy }
  end

  describe 'custom actions' do
    subject { described_class.new(user, report) }

    describe '#stop?' do
      it 'allows stopping a report' do
        expect(subject.stop?).to be true
      end
    end

    describe '#asr_history?' do
      it 'allows viewing ASR history' do
        expect(subject.asr_history?).to be true
      end
    end

    describe '#top_probes?' do
      it 'allows viewing top probes' do
        expect(subject.top_probes?).to be true
      end
    end

    describe '#probes_tab?' do
      it 'allows viewing probes tab' do
        expect(subject.probes_tab?).to be true
      end
    end

    describe '#attempt_content?' do
      it 'allows viewing attempt content' do
        expect(subject.attempt_content?).to be true
      end
    end

    describe '#probe_attempts?' do
      it 'allows viewing probe attempt rows' do
        expect(subject.probe_attempts?).to be true
      end
    end

    describe '#batch_stop?' do
      it 'allows batch stopping reports' do
        expect(subject.batch_stop?).to be true
      end
    end

    describe '#batch_destroy?' do
      it 'allows batch destroying reports' do
        expect(subject.batch_destroy?).to be true
      end
    end
  end

  describe 'Scope' do
    let!(:own_report) { ActsAsTenant.with_tenant(company) { create(:report, company: company) } }
    let!(:other_report) { ActsAsTenant.with_tenant(other_company) { create(:report, company: other_company) } }

    it 'scopes reports to current tenant' do
      ActsAsTenant.with_tenant(company) do
        scope = described_class::Scope.new(user, Report).resolve
        expect(scope).to include(own_report)
        expect(scope).not_to include(other_report)
      end
    end
  end
end
