# frozen_string_literal: true

require "rails_helper"

# The reported scan, as a shape rather than an id: 13 probes of which 9 store no prompt
# text at all, the other 4 summing to 598 tokens, against recorded actuals of 84,756
# input / 719,244 output over 89.3 minutes. The old projection showed 598 tokens and "0m".
RSpec.describe "Scan projection accuracy", type: :request do
  let(:company) { create(:company) }
  let(:user) { ActsAsTenant.with_tenant(company) { create(:user, :super_admin, company: company) } }
  let(:target) { ActsAsTenant.with_tenant(company) { create(:target, company: company, name: "Grok 4.5") } }
  let(:scan) { ActsAsTenant.with_tenant(company) { create(:complete_scan, company: company) } }

  # name => [static input_tokens, measured median input, measured median output]
  PROBE_SHAPE = {
    "av_spam_scanning.EICAR"  => [ 0,   570,   4_454 ],
    "av_spam_scanning.GTphish" => [ 0,  566,   3_751 ],
    "av_spam_scanning.GTUBE"  => [ 0,   536,   3_654 ],
    "ChemicalEscalationCM"    => [ 43,   40,     324 ],
    "ChemicalFlowChartCM"     => [ 155, 153,     415 ],
    "CorrectionRequest"       => [ 156, 618,   2_149 ],
    "DANAgreementRules"       => [ 244, 354,     469 ],
    "divergence.Repeat"       => [ 0, 1_578, 156_361 ],
    "doctor.Puppetry"         => [ 0,   690,   8_758 ],
    "encoding.InjectBase16"   => [ 0, 14_264, 390_186 ],
    "encoding.InjectBase64"   => [ 0, 15_140, 322_879 ],
    "encoding.InjectBraille"  => [ 0, 34_442, 190_743 ],
    "encoding.InjectHex"      => [ 0, 13_814, 422_669 ]
  }.freeze

  before do
    user.update!(current_company: company)
    sign_in user
    ActsAsTenant.current_tenant = company

    ActsAsTenant.with_tenant(company) do
      # The history lives on a DIFFERENT scan, so this scan has never run and the
      # projection must reconstruct it from per-probe history -- the harder rung, and the
      # one the reported defect exercised.
      past = create(:complete_scan, company: company)
      history_report = create(:report, company: company, scan: past, target: target, status: :completed,
                                       start_time: 89.minutes.ago, end_time: Time.current)
      probes = PROBE_SHAPE.map do |name, (static, input, output)|
        probe = create(:probe, name: name, input_tokens: static, prompts: static.positive? ? [ "x" ] : [])
        create(:probe_result, report: history_report, probe: probe,
                              input_tokens: input, output_tokens: output, total: 414)
        probe
      end
      scan.probes = probes
      scan.targets = [ target ]
    end
  end

  it "no longer projects the observed 598 tokens for this workload" do
    expect(scan.projection.input.amount).not_to eq(598)
  end

  it "projects input within an order of magnitude of the recorded actual" do
    actual = 84_756
    projected = scan.projection.input.amount

    expect(projected).to be > actual / 10
    expect(projected).to be < actual * 10
  end

  it "does not render this scan as approximately zero minutes" do
    get scan_path(scan)

    expect(response.body).not_to match(/~\s*0m/)
  end

  it "counts input and output as distinct quantities" do
    projection = scan.projection

    expect(projection.output.amount).not_to eq(projection.input.amount * 2)
    expect(projection.total_tokens.amount).to eq(projection.input.amount + projection.output.amount)
  end

  describe "sensitivity" do
    it "changes when probes are removed" do
      before_amount = scan.projection.input.amount
      ActsAsTenant.with_tenant(company) { scan.probes = scan.probes.limit(3).to_a }

      expect(Scans::Projection.new(scan.reload).call.input.amount).to be < before_amount
    end

    it "changes when a second target is added" do
      before_amount = scan.projection.input.amount
      ActsAsTenant.with_tenant(company) do
        scan.targets = [ target, create(:target, company: company, name: "Second") ]
      end

      expect(Scans::Projection.new(scan.reload).call.input.amount).to be > before_amount
    end
  end

  describe "a small workload" do
    it "still projects rather than reporting nothing" do
      small = ActsAsTenant.with_tenant(company) { create(:complete_scan, company: company) }
      ActsAsTenant.with_tenant(company) do
        small.probes = [ Probe.find_by(name: "ChemicalEscalationCM") ]
        small.targets = [ target ]
      end

      expect(small.projection.input).to be_available
    end
  end
end
