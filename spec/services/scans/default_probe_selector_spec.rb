require 'rails_helper'

RSpec.describe Scans::DefaultProbeSelector, type: :service do
  describe '#call' do
    let(:company) { create(:company) }
    let(:scan) { create(:complete_scan, company: company) }
    let(:report) { create(:report, :completed, company: company, scan: scan, target: create(:target, company: company)) }

    before { ActsAsTenant.current_tenant = company }

    def seed(name:, passed:, total:, rpt: report)
      probe = create(:probe, name: name)
      create(:probe_result, report: rpt, probe: probe, passed: passed, total: total)
      probe
    end

    it 'returns a Set of probe ids ordered by ASR (most successful first)' do
      low  = seed(name: 'attack.low',  passed: 1, total: 10) # 10%
      high = seed(name: 'attack.high', passed: 9, total: 10) # 90%
      mid  = seed(name: 'attack.mid',  passed: 5, total: 10) # 50%

      result = described_class.new(probe_scope: Probe.all).call

      expect(result).to be_a(Set)
      expect(result.to_a).to eq([ high.id, mid.id, low.id ])
    end

    it 'respects the limit' do
      (1..6).each { |i| seed(name: "attack.#{i}", passed: i, total: 10) }
      expect(described_class.new(probe_scope: Probe.all, limit: 3).call.size).to eq(3)
    end

    it 'excludes probes below the minimum-attempts floor' do
      strong = seed(name: 'attack.strong', passed: 5, total: 10) # 5 attempts >= floor
      tiny   = seed(name: 'attack.tiny',   passed: 3, total: 3)  # 3 attempts < floor

      result = described_class.new(probe_scope: Probe.all, min_attempts: 5).call

      expect(result).to include(strong.id)
      expect(result).not_to include(tiny.id)
    end

    it 'never divides by zero even when the attempts floor is lowered to zero' do
      has_attempts = seed(name: 'attack.has', passed: 1, total: 2)
      zero_attempts = seed(name: 'attack.zero', passed: 0, total: 0)

      result = nil
      expect { result = described_class.new(probe_scope: Probe.all, min_attempts: 0).call }.not_to raise_error
      expect(result).to include(has_attempts.id)
      expect(result).not_to include(zero_attempts.id)
    end

    it 'excludes custom probes' do
      builtin = seed(name: 'attack.builtin', passed: 8, total: 10)
      custom  = create(:probe, name: 'attack.custom')
      custom.update_column(:source, 'custom')
      create(:probe_result, report: report, probe: custom, passed: 9, total: 10)

      result = described_class.new(probe_scope: Probe.all).call

      expect(result).to include(builtin.id)
      expect(result).not_to include(custom.id)
    end

    it 'only counts probes within the provided scope' do
      included = seed(name: 'attack.included', passed: 8, total: 10)
      seed(name: 'attack.excluded', passed: 9, total: 10)

      result = described_class.new(probe_scope: Probe.where(id: included.id)).call

      expect(result.to_a).to eq([ included.id ])
    end

    it 'ignores non-completed reports' do
      visible = seed(name: 'attack.visible', passed: 6, total: 10)

      failed = create(:report, :failed, company: company, scan: scan, target: create(:target, company: company))
      seed(name: 'attack.failed', passed: 9, total: 10, rpt: failed)

      result = described_class.new(probe_scope: Probe.all).call

      expect(result.to_a).to eq([ visible.id ])
    end

    it 'returns an empty Set when there is no qualifying data' do
      expect(described_class.new(probe_scope: Probe.all).call).to eq(Set.new)
    end

    it 'only aggregates the current tenant reports' do
      mine = seed(name: 'attack.mine', passed: 5, total: 10)
      other = create(:company)
      ActsAsTenant.with_tenant(other) do
        oscan = create(:complete_scan, company: other)
        orpt = create(:report, :completed, company: other, scan: oscan, target: create(:target, company: other))
        op = create(:probe, name: 'attack.theirs')
        create(:probe_result, report: orpt, probe: op, passed: 9, total: 10)
      end

      result = described_class.new(probe_scope: Probe.all).call
      expect(result.to_a).to eq([ mine.id ])
    end
  end
end
