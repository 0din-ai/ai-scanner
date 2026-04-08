# frozen_string_literal: true

require "rails_helper"

RSpec.describe GenerateVariantReportsJob, type: :job do
  let(:company) { create(:company) }
  let(:probe) { create(:probe, name: "TestProbe", category: "0din", source: "0din") }
  let(:detector) { create(:detector) }
  let(:scan) { create(:complete_scan, company: company) }
  let(:target) { scan.targets.first }
  let(:report) { create(:report, :completed, scan: scan, target: target, company: company) }

  let(:industry) { ThreatVariantIndustry.create!(name: "Automotive") }
  let(:subindustry) { ThreatVariantSubindustry.create!(name: "Autonomous Driving", threat_variant_industry: industry) }
  let!(:threat_variant) do
    ThreatVariant.create!(probe: probe, threat_variant_subindustry: subindustry, prompt: "Variant_TestProbe_Automotive_Autonomous_Driving")
  end

  before do
    scan.probes << probe unless scan.probes.include?(probe)
  end

  describe "#perform" do
    context "when scan has no threat variants selected" do
      it "does nothing" do
        report # force creation before measuring count
        expect { described_class.new.perform(report.id) }.not_to change(Report, :count)
      end
    end

    context "when report is a variant (child) report" do
      let(:child_report) do
        create(:report, :completed, scan: scan, target: target, company: company, parent_report_id: report.id)
      end

      it "does nothing" do
        scan.threat_variant_subindustries << subindustry
        child_report # force creation before measuring count
        expect { described_class.new.perform(child_report.id) }.not_to change(Report, :count)
      end
    end

    context "when scan has threat variants and parent report has passed probes" do
      before do
        scan.threat_variant_subindustries << subindustry
        create(:probe_result, report: report, probe: probe, detector: detector, passed: 5, total: 10)
      end

      it "creates a child variant report" do
        allow_any_instance_of(RunGarakScan).to receive(:call)

        expect { described_class.new.perform(report.id) }.to change(Report, :count).by(1)

        child = Report.find_by(parent_report_id: report.id)
        expect(child).to be_present
        expect(child.status).to eq("pending")
        expect(child.name).to include("All Variants")
        expect(child.company).to eq(company)
        expect(child.scan).to eq(scan)
        expect(child.target).to eq(target)
      end

      it "associates variant probes on the child report" do
        allow_any_instance_of(RunGarakScan).to receive(:call)

        described_class.new.perform(report.id)

        child = Report.find_by(parent_report_id: report.id)
        expect(child.variant_probes).to include(probe)
      end

      it "calls RunGarakScan on the child report" do
        expect_any_instance_of(RunGarakScan).to receive(:call)

        described_class.new.perform(report.id)
      end
    end

    context "when no probes passed in parent report" do
      before do
        scan.threat_variant_subindustries << subindustry
        create(:probe_result, report: report, probe: probe, detector: detector, passed: 0, total: 10)
      end

      it "does nothing" do
        expect { described_class.new.perform(report.id) }.not_to change(Report, :count)
      end
    end

    context "when no variant mappings exist for passed probes" do
      let(:other_probe) { create(:probe, name: "OtherProbe", category: "0din", source: "0din") }

      before do
        scan.probes << other_probe
        scan.threat_variant_subindustries << subindustry
        create(:probe_result, report: report, probe: other_probe, detector: detector, passed: 5, total: 10)
      end

      it "does not create a child report" do
        expect { described_class.new.perform(report.id) }.not_to change(Report, :count)
      end
    end
  end

  describe "queue configuration" do
    it "uses default queue" do
      expect(described_class.new.queue_name).to eq("default")
    end
  end
end
