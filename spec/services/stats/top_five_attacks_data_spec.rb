require 'rails_helper'

RSpec.describe Stats::TopFiveAttacksData, type: :service do
  describe '#call' do
    let(:company) { create(:company) }
    let(:scan) { create(:complete_scan, company: company) }
    let(:report) { create(:report, :completed, company: company, scan: scan, target: create(:target, company: company)) }

    before { ActsAsTenant.current_tenant = company }

    def probe_result_for(name:, passed:, total:, rpt: report)
      probe = create(:probe, name: name)
      create(:probe_result, report: rpt, probe: probe, passed: passed, total: total)
      probe
    end

    context 'ranking' do
      before do
        probe_result_for(name: 'attack.low',  passed: 1, total: 10) # 10%
        probe_result_for(name: 'attack.high', passed: 9, total: 10) # 90%
        probe_result_for(name: 'attack.mid',  passed: 5, total: 10) # 50%
      end

      it 'orders probes by ASR descending and rounds to integers' do
        result = described_class.new(probe_scope: Probe.all).call

        expect(result.map { |r| r[:probe_name] }).to eq([ 'attack.high', 'attack.mid', 'attack.low' ])
        expect(result.map { |r| r[:asr] }).to eq([ 90, 50, 10 ])
        expect(result.first[:probe_id]).to be_present
      end
    end

    context 'with more than five probes' do
      before { (1..6).each { |i| probe_result_for(name: "attack.#{i}", passed: i, total: 10) } }

      it 'limits to five' do
        expect(described_class.new(probe_scope: Probe.all).call.length).to eq(5)
      end
    end

    context 'tie-break on volume' do
      before do
        probe_result_for(name: 'attack.small', passed: 1, total: 1)   # 100%, total 1
        probe_result_for(name: 'attack.big',   passed: 10, total: 10) # 100%, total 10
      end

      it 'orders equal-ASR probes by total descending' do
        result = described_class.new(probe_scope: Probe.all).call
        expect(result.map { |r| r[:probe_name] }).to eq([ 'attack.big', 'attack.small' ])
      end
    end

    context 'probes with zero total' do
      before do
        probe_result_for(name: 'attack.zero', passed: 0, total: 0)
        probe_result_for(name: 'attack.real', passed: 4, total: 10)
      end

      it 'excludes probes with no tests' do
        result = described_class.new(probe_scope: Probe.all).call
        expect(result.map { |r| r[:probe_name] }).to eq([ 'attack.real' ])
      end
    end

    context 'non-completed reports' do
      before do
        probe_result_for(name: 'attack.visible', passed: 5, total: 10)
        failed = create(:report, :failed, company: company, scan: scan, target: create(:target, company: company))
        probe_result_for(name: 'attack.failed', passed: 9, total: 10, rpt: failed)
      end

      it 'excludes results from failed/incomplete reports' do
        result = described_class.new(probe_scope: Probe.all).call
        expect(result.map { |r| r[:probe_name] }).to eq([ 'attack.visible' ])
      end
    end

    context 'probe_scope filtering' do
      before do
        @included = probe_result_for(name: 'attack.included', passed: 8, total: 10)
        probe_result_for(name: 'attack.excluded', passed: 9, total: 10)
      end

      it 'only counts probes within the provided scope' do
        result = described_class.new(probe_scope: Probe.where(id: @included.id)).call
        expect(result.map { |r| r[:probe_name] }).to eq([ 'attack.included' ])
      end
    end

    context 'tenant isolation' do
      before do
        probe_result_for(name: 'attack.mine', passed: 5, total: 10)
        other = create(:company)
        ActsAsTenant.with_tenant(other) do
          oscan = create(:complete_scan, company: other)
          orpt = create(:report, :completed, company: other, scan: oscan, target: create(:target, company: other))
          op = create(:probe, name: 'attack.theirs')
          create(:probe_result, report: orpt, probe: op, passed: 9, total: 10)
        end
      end

      it 'only aggregates the current tenant reports' do
        result = described_class.new(probe_scope: Probe.all).call
        expect(result.map { |r| r[:probe_name] }).to eq([ 'attack.mine' ])
      end
    end
  end
end
