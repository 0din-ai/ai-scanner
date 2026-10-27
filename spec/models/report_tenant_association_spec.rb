require "rails_helper"

RSpec.describe Report, type: :model do
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let(:scan) { create(:complete_scan, company: company) }

  it "allows a historical report to reference its company's deleted target" do
    target = create(:target, :deleted, company: company)
    report = build(:report, company: company, scan: scan, target: target)

    expect(report).to be_valid
  end

  [ false, true ].each do |deleted|
    it "rejects a #{deleted ? 'deleted' : 'live'} target belonging to another company" do
      target = create(:target, company: other_company, deleted_at: deleted ? Time.current : nil)
      report = build(:report, company: company, scan: scan, target: target)

      expect(report).not_to be_valid
      expect(report.errors.details[:target_id]).to include(error: :"acts_as_tenant.association_invalid")
    end
  end
end
