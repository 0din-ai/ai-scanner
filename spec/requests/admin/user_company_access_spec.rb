require "rails_helper"

RSpec.describe "User company access", type: :request do
  let(:a) { create(:company, name: "Account Alpha") }
  let(:b) { create(:company, name: "Account Beta") }
  let(:admin) { create(:user, :super_admin, company: a) }
  let(:member) { create(:user, company: a) }

  before { sign_in admin }

  def form_document
    Nokogiri::HTML(response.body)
  end

  it "shows membership and active-company controls to a super admin" do
    b
    get new_user_path

    expect(response).to have_http_status(:ok)
    expect(form_document.css('input[name="user[company_ids][]"][type="checkbox"]').size).to eq(2)
    expect(form_document.at_css('select[name="user[current_company_id]"]')).to be_present
  end

  it "creates memberships through the actual admin form parameters" do
    post users_path, params: { user: {
      email: "new-member@example.com", password: "password123", password_confirmation: "password123",
      company_ids: [ "", a.id.to_s, b.id.to_s ], current_company_id: b.id.to_s
    } }

    record = User.find_by!(email: "new-member@example.com")
    expect(response).to redirect_to(user_path(record))
    expect(record.companies).to contain_exactly(a, b)
    expect(record.current_company).to eq(b)
    expect(b.users).to include(record)
  end

  it "keeps submitted choices visible on a failed save without changing the database" do
    patch user_path(member), params: { user: { email: "invalid", company_ids: [ b.id ], current_company_id: b.id } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(form_document.at_css("input[name='user[company_ids][]'][value='#{b.id}']")['checked']).to eq("checked")
    expect(form_document.at_css("select[name='user[current_company_id]'] option[value='#{b.id}']")['selected']).to eq("selected")
    expect(member.reload.companies).to contain_exactly(a)
    expect(member.current_company).to eq(a)
  end

  it "does not allow a regular user to edit membership or active-company fields" do
    sign_out admin
    sign_in member
    patch user_path(member), params: { user: { company_ids: [ b.id ], current_company_id: b.id } }

    expect(response).to redirect_to(user_path(member))
    expect(member.reload.companies).to contain_exactly(a)
    expect(member.current_company).to eq(a)
    get edit_user_path(member)
    expect(form_document.at_css('input[name="user[company_ids][]"]')).to be_nil
    expect(form_document.at_css('select[name="user[current_company_id]"]')).to be_nil
  end

  it "allows a shared-company member to view a colleague active in another company" do
    colleague = create(:user, company: b)
    create(:membership, user: colleague, company: a)
    sign_out admin
    sign_in member

    get users_path
    expect(response.body).to include(colleague.email)
    get user_path(colleague)
    expect(response).to have_http_status(:ok)
  end

  it "keeps switching within existing memberships without dropping access" do
    create(:membership, user: member, company: b)
    sign_out admin
    sign_in member

    patch switch_company_path(b)

    expect(member.reload.current_company).to eq(b)
    expect(member.companies).to contain_exactly(a, b)
  end

  it "lets a genuinely membership-free legacy account view only its own profile" do
    orphan = build(:user)
    orphan.save!
    other_orphan = build(:user)
    other_orphan.save!
    expect(orphan.memberships).to be_empty
    expect(orphan.current_company_id).to be_nil
    sign_out admin
    sign_in orphan

    get user_path(orphan)
    expect(response).to have_http_status(:ok)
    get users_path
    expect(response.body).to include(orphan.email)
    expect(response.body).not_to include(other_orphan.email)
    expect(response.body).not_to include(member.email)
    get user_path(other_orphan)
    expect(response).to redirect_to(users_path)
  end
end
