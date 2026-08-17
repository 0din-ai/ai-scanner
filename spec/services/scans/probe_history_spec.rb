# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scans::ProbeHistory do
  let(:company) { create(:company) }
  let(:probe) { create(:probe, name: "encoding.InjectBase64") }

  def record(input:, output:, total: 10, company_for: company, target: nil)
    ActsAsTenant.with_tenant(company_for) do
      scan = create(:complete_scan, company: company_for)
      tgt = target || create(:target, company: company_for)
      report = create(:report, company: company_for, scan: scan, target: tgt, status: :completed)
      create(:probe_result, report: report, probe: probe,
                            input_tokens: input, output_tokens: output, total: total)
    end
  end

  it "returns the median, not the mean, of a probe's recorded usage" do
    # divergence.Repeat averages 156k output tokens over four runs; the mean is what
    # pushed the projection 2.1x over. The median resists that.
    [ 100, 200, 5_000 ].each { |v| record(input: v, output: v * 2) }

    result = described_class.for(company: company, probe_ids: [ probe.id ])

    expect(result[probe.id][:input]).to eq(200)
    expect(result[probe.id][:output]).to eq(400)
  end

  it "sums a run's variant children into that run before taking the median" do
    # A variant child records its own probe_result row against the SAME base probe as its
    # parent, so a percentile taken across individual rows read this family as ~20 tokens
    # when the family actually cost 300. Scans::Projection deliberately applies no variant
    # multiplier -- variant rows are meant to be represented in history already -- so the
    # understatement went straight into the projection of any scan carrying variants.
    ActsAsTenant.with_tenant(company) do
      past = create(:complete_scan, company: company)
      tgt = create(:target, company: company)
      parent = create(:report, company: company, scan: past, target: tgt, status: :completed)
      create(:probe_result, report: parent, probe: probe,
                            input_tokens: 100, output_tokens: 200, total: 10)
      # One variant child per run (Report allows a single child), carrying one
      # probe_result per threat variant -- all against the same base probe, which is
      # exactly what ProbeResult's (report, probe, threat_variant) uniqueness permits.
      child = create(:report, company: company, scan: past, target: tgt,
                              status: :completed, parent_report: parent)
      subindustry = create(:threat_variant_subindustry)
      10.times do
        variant = create(:threat_variant, probe: probe, threat_variant_subindustry: subindustry)
        create(:probe_result, report: child, probe: probe, threat_variant: variant,
                              input_tokens: 20, output_tokens: 40, total: 2)
      end
    end

    result = described_class.for(company: company, probe_ids: [ probe.id ])

    expect(result[probe.id][:input]).to eq(300)     # 100 + 10 * 20, not the 20 a row-wise median gave
    expect(result[probe.id][:output]).to eq(600)    # 200 + 10 * 40
    expect(result[probe.id][:evaluated]).to eq(30)  # 10  + 10 * 2
  end

  it "takes the median ACROSS runs rather than summing them" do
    # The fix above aggregates within a run; it must not aggregate across runs, or a probe
    # would be projected at everything it has ever cost cumulatively.
    [ 300, 100 ].each do |input|
      ActsAsTenant.with_tenant(company) do
        past = create(:complete_scan, company: company)
        report = create(:report, company: company, scan: past,
                                 target: create(:target, company: company), status: :completed)
        create(:probe_result, report: report, probe: probe,
                              input_tokens: input, output_tokens: input, total: 10)
      end
    end

    result = described_class.for(company: company, probe_ids: [ probe.id ])

    # percentile_cont interpolates: the median of two runs is their midpoint, not 400.
    expect(result[probe.id][:input]).to eq(200)
  end

  it "ignores another tenant's history entirely" do
    # ProbeResult has no company_id -- it is tenant-scoped only through its report, so an
    # unscoped query silently reads every tenant's data and leaks how verbose their
    # targets are.
    other = create(:company)
    record(input: 1_000_000, output: 1_000_000, company_for: other)
    record(input: 500, output: 700)

    result = described_class.for(company: company, probe_ids: [ probe.id ])

    expect(result[probe.id][:input]).to eq(500)
  end

  it "reads only runs that measured a workload to completion" do
    # An unfinished run is not evidence of what a probe costs: a failed or partial run
    # measured less work than it planned.
    record(input: 500, output: 700)
    ineligible = [
      ->(report) { report.update_columns(result_completeness: "partial") },
      ->(report) { report.update_columns(status: Report.statuses[:failed]) }
    ]
    ineligible.each do |make_ineligible|
      ActsAsTenant.with_tenant(company) do
        scan = create(:complete_scan, company: company)
        report = create(:report, company: company, scan: scan,
                                 target: create(:target, company: company), status: :completed)
        make_ineligible.call(report)
        create(:probe_result, report: report, probe: probe,
                              input_tokens: 999_999, output_tokens: 999_999, total: 10)
      end
    end

    result = described_class.for(company: company, probe_ids: [ probe.id ])

    # percentile_cont interpolates, so any leaked sample moves this off the lone
    # eligible run's values rather than merely nudging them.
    expect(result[probe.id][:input]).to eq(500)
    expect(result[probe.id][:output]).to eq(700)
  end

  it "omits probes that have never run" do
    never_run = create(:probe, name: "NeverRun")

    result = described_class.for(company: company, probe_ids: [ probe.id, never_run.id ])

    expect(result).not_to have_key(never_run.id)
  end

  it "prefers history for the requested target when asked" do
    grok = ActsAsTenant.with_tenant(company) { create(:target, company: company, name: "Grok") }
    record(input: 900, output: 900, target: grok)
    record(input: 100, output: 100)

    result = described_class.for(company: company, probe_ids: [ probe.id ], target_id: grok.id)

    expect(result[probe.id][:input]).to eq(900)
  end

  it "falls back to tenant-wide history when the probe has none for the requested target" do
    # A newly created target has no same-target history yet, but the tenant may have run
    # this probe plenty against other targets -- discarding that entirely is the bug: it
    # turns "no same-target sample" into "no evidence at all" for exactly the case
    # (single-target scan, never-run target) this ladder rung exists to answer.
    grok = ActsAsTenant.with_tenant(company) { create(:target, company: company, name: "Grok") }
    other_target = ActsAsTenant.with_tenant(company) { create(:target, company: company, name: "Other") }
    record(input: 700, output: 700, target: other_target)

    result = described_class.for(company: company, probe_ids: [ probe.id ], target_id: grok.id)

    expect(result[probe.id][:input]).to eq(700)
  end

  it "draws each probe from the right source when only some have same-target history" do
    probe_two = create(:probe, name: "encoding.InjectBase16")
    grok = ActsAsTenant.with_tenant(company) { create(:target, company: company, name: "Grok") }
    other_target = ActsAsTenant.with_tenant(company) { create(:target, company: company, name: "Other") }

    # `probe` has both same-target and other-target history -- same-target must win.
    record(input: 900, output: 900, target: grok)
    record(input: 100, output: 100, target: other_target)

    # `probe_two` has only other-target history -- it must fall back rather than vanish.
    ActsAsTenant.with_tenant(company) do
      scan = create(:complete_scan, company: company)
      report = create(:report, company: company, scan: scan, target: other_target, status: :completed)
      create(:probe_result, report: report, probe: probe_two,
                            input_tokens: 300, output_tokens: 300, total: 10)
    end

    result = described_class.for(company: company, probe_ids: [ probe.id, probe_two.id ], target_id: grok.id)

    expect(result[probe.id][:input]).to eq(900)
    expect(result[probe_two.id][:input]).to eq(300)
  end

  it "does not leak another company's history through the fallback path" do
    # The fallback query is broader than the same-target one -- exactly where a tenant
    # scoping mistake would slip in unnoticed.
    other = create(:company)
    grok = ActsAsTenant.with_tenant(company) { create(:target, company: company, name: "Grok") }
    record(input: 1_000_000, output: 1_000_000, company_for: other)

    result = described_class.for(company: company, probe_ids: [ probe.id ], target_id: grok.id)

    expect(result).not_to have_key(probe.id)
  end

  it "reads every probe in one query regardless of how many there are" do
    probes = Array.new(5) { |i| create(:probe, name: "Bulk#{i}") }
    probes.each do |p|
      ActsAsTenant.with_tenant(company) do
        scan = create(:complete_scan, company: company)
        report = create(:report, company: company, scan: scan,
                                 target: create(:target, company: company), status: :completed)
        create(:probe_result, report: report, probe: p, input_tokens: 10, output_tokens: 10, total: 1)
      end
    end

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/ }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      described_class.for(company: company, probe_ids: probes.map(&:id))
    end

    expect(queries).to eq(1)
  end
end
