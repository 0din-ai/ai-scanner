require "rails_helper"

RSpec.describe Users::SaveWithCompanyAccess do
  let(:a) { create(:company) }
  let(:b) { create(:company) }
  let(:c) { create(:company) }
  let(:user) { create(:user, company: a) }

  it "creates a user with a real membership and default active company" do
    record = build(:user)
    saver = described_class.new(record, {}, default_company: a)

    expect(saver.call).to be true
    expect(record.reload.current_company).to eq(a)
    expect(record.companies).to contain_exactly(a)
    expect(a.users).to include(record)
  end

  it "saves multiple memberships and an active company" do
    saver = described_class.new(user, { company_ids: [ "", a.id.to_s, b.id.to_s, b.id.to_s ], current_company_id: b.id.to_s })

    expect(saver.call).to be true
    expect(user.reload.companies).to contain_exactly(a, b)
    expect(user.current_company).to eq(b)
  end

  it "adds active-only assignments without removing other memberships" do
    create(:membership, user: user, company: b)

    expect(described_class.new(user, { current_company_id: c.id }).call).to be true
    expect(user.reload.companies).to contain_exactly(a, b, c)
    expect(user.current_company).to eq(c)
  end

  it "removes only explicitly deselected memberships" do
    create(:membership, user: user, company: b)

    expect(described_class.new(user, { company_ids: [ b.id ], current_company_id: b.id }).call).to be true
    expect(user.reload.companies).to contain_exactly(b)
  end

  it "requires another active company before its membership can be removed" do
    create(:membership, user: user, company: b)
    saver = described_class.new(user, { company_ids: [ b.id ] })

    expect(saver.call).to be false
    expect(user.errors[:current_company]).to be_present
    expect(user.reload.companies).to contain_exactly(a, b)
    expect(user.current_company).to eq(a)
  end

  it "rejects an explicitly empty selection without deleting memberships" do
    saver = described_class.new(user, { company_ids: [ "" ], current_company_id: "" })

    expect(saver.call).to be false
    expect(saver.selected_company_ids).to eq([])
    expect(saver.current_company_id).to be_nil
    expect(user.reload.companies).to contain_exactly(a)
  end

  [ "not-an-id", "1trailing", "-1", "0", "9" * 30 ].each do |invalid_id|
    it "rejects malformed company ID #{invalid_id.inspect}" do
      saver = described_class.new(user, { company_ids: [ a.id, invalid_id ], current_company_id: a.id })

      expect(saver.call).to be false
      expect(user.errors[:companies]).to be_present
      expect(user.reload.companies).to contain_exactly(a)
    end
  end

  it "rejects malformed active-company IDs before Rails can coerce them" do
    saver = described_class.new(user, { current_company_id: "#{b.id}trailing" })

    expect(saver.call).to be false
    expect(user.errors[:current_company]).to be_present
    expect(user.reload.current_company).to eq(a)
    expect(user.companies).to contain_exactly(a)
  end

  it "rejects companies that do not exist" do
    user
    nonexistent_id = Company.maximum(:id) + 1
    saver = described_class.new(user, { company_ids: [ nonexistent_id ], current_company_id: nonexistent_id })

    expect(saver.call).to be false
    expect(user.errors[:companies]).to be_present
    expect(user.reload.companies).to contain_exactly(a)
  end

  it "does not change access when user validation fails" do
    saver = described_class.new(user, { email: "invalid", company_ids: [ b.id ], current_company_id: b.id })

    expect(saver.call).to be false
    expect(saver.selected_company_ids).to eq([ b.id ])
    expect(saver.current_company_id).to eq(b.id)
    expect(user.reload.current_company).to eq(a)
    expect(user.companies).to contain_exactly(a)
  end

  it "rolls back ordinary fields and active company if the join update fails" do
    previous_email = user.email
    allow(user).to receive(:company_ids=).and_raise(ActiveRecord::RecordNotSaved)
    saver = described_class.new(user, { email: "changed@example.com", company_ids: [ b.id ], current_company_id: b.id })

    expect(saver.call).to be false
    expect(user.reload.email).to eq(previous_email)
    expect(user.current_company).to eq(a)
    expect(user.companies).to contain_exactly(a)
  end

  it "preserves access and form selections on an ordinary-only invalid update" do
    saver = described_class.new(user, { email: "invalid" })

    expect(saver.call).to be false
    expect(saver.selected_company_ids).to eq([ a.id ])
    expect(saver.current_company_id).to eq(a.id)
    expect(user.reload.current_company).to eq(a)
  end
end
