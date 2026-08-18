# frozen_string_literal: true

require "rails_helper"

# The reported confusion, as two fixtures:
#
#   * one report showed a probe at 2.2% (4/180) on the overview and a detector at
#     100% (180/180) in the details. Both were right -- different levels, different
#     denominators -- but nothing on the page said so.
#   * another showed two rows both reading "Generic Mitigation Bypass Checks", one
#     4/4 and one 185/185, with no way to tell which was which.
RSpec.describe "Reconciling report metrics", type: :request do
  let(:company) { create(:company) }
  let(:user) { ActsAsTenant.with_tenant(company) { create(:user, :super_admin, company: company) } }
  let(:scan) { ActsAsTenant.with_tenant(company) { create(:complete_scan, company: company) } }
  let(:target) { ActsAsTenant.with_tenant(company) { create(:target, company: company) } }

  before do
    user.update!(current_company: company)
    sign_in user
    ActsAsTenant.current_tenant = company
  end

  context "a probe rate and a detector rate that look contradictory" do
    let!(:report) do
      ActsAsTenant.with_tenant(company) do
        report = create(:report, company: company, scan: scan, target: target, status: :completed)
        detector = create(:detector, name: "divergence.Repeat")
        probe = create(:probe, name: "RepeatDiverges", detector: detector)
        # 4 of 180 attempts succeeded for the probe...
        create(:probe_result, report: report, probe: probe, detector: detector, passed: 4, total: 180)
        # ...while the detector evaluated all 180 outputs and fired on every one.
        create(:detector_result, report: report, detector: detector, passed: 180, total: 180)
        report
      end
    end

    # The two figures live on different surfaces -- detector stats on the overview, probe
    # rows in the lazily-loaded probes tab -- which is part of why they were hard to
    # reconcile. Each states its own level and basis.
    it "states the detector table's level and basis on the overview" do
      get report_path(report)

      expect(response.body).to match(/one row per detector/i)
      # Reports::Process assigns the same total_evaluated to detector_stats[:total] as to
      # ProbeResult#total. garak's evaluator sets it to passes + fails counted once per
      # entry in attempt.detector_results, which aligns with attempt.outputs -- so this
      # counts outputs, and one prompt run with several generations counts several times.
      expect(response.body).to match(/outputs that detector evaluated/i)
      expect(response.body).to include("180 / 180").or include("180/180")
    end

    it "states the probe table's level and basis on the probes tab" do
      get probes_tab_report_path(report)

      expect(response.body).to match(/one row per probe/i)
      expect(response.body).to match(/outputs evaluated for that probe/i)
      expect(response.body).to include("4 / 180").or include("4/180")
    end
  end

  context "two detectors sharing one friendly name" do
    let!(:report) do
      ActsAsTenant.with_tenant(company) do
        report = create(:report, company: company, scan: scan, target: target, status: :completed)
        create(:detector_result, report: report, detector: create(:detector, name: "0din.MitigationBypass"),
                                 passed: 4, total: 4)
        create(:detector_result, report: report, detector: create(:detector, name: "mitigation.MitigationBypass"),
                                 passed: 185, total: 185)
        report
      end
    end

    it "distinguishes the rows by the identifier behind the shared label" do
      get report_path(report)

      expect(response.body).to include("0din.MitigationBypass")
      expect(response.body).to include("mitigation.MitigationBypass")
    end

    it "distinguishes the detector cards on the customer report too" do
      # The customer page and its PDF render their own detector cards; without the
      # identifier they are two identical "Generic Mitigation Bypass Checks" tiles.
      get report_detail_path(report)

      expect(response.body).to include("0din.MitigationBypass")
      expect(response.body).to include("mitigation.MitigationBypass")
    end

    it "distinguishes the detector behind each probe row" do
      ActsAsTenant.with_tenant(company) do
        odin = Detector.find_by(name: "0din.MitigationBypass")
        create(:probe_result, report: report, probe: create(:probe, name: "SharedLabelProbe"),
                              detector: odin, passed: 1, total: 2)
      end

      get probes_tab_report_path(report)

      expect(response.body).to include("0din.MitigationBypass")
    end
  end

  describe "a variant child report, whose rows are one per probe and variant" do
    let(:parent) do
      ActsAsTenant.with_tenant(company) { create(:report, company: company, scan: scan, target: target) }
    end

    let(:report) do
      ActsAsTenant.with_tenant(company) do
        child = create(:report, company: company, scan: scan, target: target,
                                status: :completed, parent_report: parent)
        probe = create(:probe, name: "SharedProbe")
        # A variant child records one result per threat variant, so the same probe
        # appears on several rows -- each with its own variant-scoped denominator.
        2.times do |i|
          create(:probe_result, report: child, probe: probe,
                                threat_variant: create(:threat_variant, probe: probe, prompt: "Variant #{i}"),
                                passed: 1, total: 5)
        end
        child
      end
    end

    it "does not claim one row per probe when a probe spans several rows" do
      get probes_tab_report_path(report)

      expect(response.body).not_to include("One row per probe —")
      expect(response.body).to include("One row per probe and threat variant")
    end
  end

  describe "a child report whose results predate threat variants" do
    let(:parent) do
      ActsAsTenant.with_tenant(company) { create(:report, company: company, scan: scan, target: target) }
    end

    let(:report) do
      ActsAsTenant.with_tenant(company) do
        # is_variant_report? is true for any child, but a child recorded before
        # threat_variant_id existed holds ordinary per-probe rows -- a shape the
        # customer view still supports via variant_industry_tag's nil fallback.
        child = create(:report, company: company, scan: scan, target: target,
                                status: :completed, parent_report: parent)
        create(:probe_result, report: child, probe: create(:probe, name: "LegacyProbe"),
                              threat_variant: nil, passed: 1, total: 5)
        child
      end
    end

    it "describes the rows it actually renders, not the report type" do
      get probes_tab_report_path(report)

      expect(response.body).to include("One row per probe —")
      expect(response.body).not_to include("One row per probe and threat variant")
    end
  end

  describe "the denominator the probe rate is taken over" do
    let(:report) do
      ActsAsTenant.with_tenant(company) do
        r = create(:report, company: company, scan: scan, target: target, status: :completed)
        create(:probe_result, report: r, probe: create(:probe, name: "CountedProbe"), passed: 1, total: 4)
        r
      end
    end

    it "names evaluated outputs rather than attempts" do
      # ProbeResult#total is garak's total_evaluated: one count per evaluated output.
      # "Attempts" names a different collection, so using it here would restate the
      # ticket's own defect in the copy meant to fix it.
      get probes_tab_report_path(report)

      expect(response.body).to include("outputs evaluated")
      expect(response.body).not_to include("rate over the attempts")
    end
  end

  context "a report where every attack was blocked" do
    let!(:report) do
      ActsAsTenant.with_tenant(company) do
        report = create(:report, company: company, scan: scan, target: target, status: :completed)
        detector = create(:detector, name: "mitigation.MitigationBypass")
        probe = create(:probe, name: "Blocked", detector: detector)
        create(:probe_result, report: report, probe: probe, detector: detector, passed: 0, total: 84)
        create(:detector_result, report: report, detector: detector, passed: 0, total: 84)
        report
      end
    end

    # "0 / 84 attacks succeeded" and "2 vulnerabilities found" cannot both describe the
    # same report. The overview showed exactly that.
    it "does not claim vulnerabilities next to a zero success rate" do
      get report_path(report)

      expect(response.body).to include("0 / 84")
      expect(report.security_vulnerabilities_count).to eq(0)
    end
  end
end
