require "rails_helper"

RSpec.describe "User form navigation updates", type: :request do
  let(:original_company) { create(:company, name: "Default Organization") }
  let(:research) { create(:company, name: "Research") }
  let(:operations) { create(:company, name: "Operations") }
  let(:admin) { create(:user, :super_admin, company: original_company) }
  let(:drive_headers) { { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" } }

  before do
    post user_session_path, params: { user: { email: admin.email, password: "password123" } }
    expect(response).to redirect_to(root_path)
  end

  def document
    Nokogiri::HTML(response.body)
  end

  [ :new, :edit ].each do |action|
    it "targets the top page when the #{action} form is loaded inside main-content" do
      path = action == :new ? new_user_path : edit_user_path(admin)
      get path, headers: { "Turbo-Frame" => "main-content" }

      expect(response).to have_http_status(:ok)
      expect(document.at_css("turbo-frame#main-content")).to be_present
      form_action = action == :new ? users_path : user_path(admin)
      form = document.at_css("form[action='#{form_action}']")
      expect(form["data-turbo-frame"]).to eq("_top")
      expect(form["data-turbo"]).not_to eq("false")
    end
  end

  it "renders the new own-company switcher in the save redirect without an extra reload" do
    get edit_user_path(admin)
    expect(document.at_css('#main-menu [data-controller="company-switcher"]')).to be_nil

    patch user_path(admin), params: { user: {
      company_ids: [ "", research.id, operations.id ], current_company_id: operations.id
    } }, headers: drive_headers

    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(user_path(admin))
    follow_redirect!(headers: drive_headers)

    expect(response).to have_http_status(:ok)
    switcher = document.at_css('#main-menu [data-controller="company-switcher"]')
    expect(switcher).to be_present
    expect(switcher.at_css('[data-action="click->company-switcher#toggle"]').text).to include(operations.name)
    menu = switcher.at_css('[data-company-switcher-target="menu"]')
    expect(menu.text).to include(research.name, operations.name)
    expect(menu.text).not_to include(original_company.name)
    expect(admin.reload.companies).to contain_exactly(research, operations)
    expect(admin.current_company).to eq(operations)
  end

  it "retains top-target validation choices and unchanged access in a full-page 422 response" do
    patch user_path(admin), params: { user: {
      company_ids: [ "", research.id ], current_company_id: operations.id
    } }, headers: drive_headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(document.at_css("#main-menu")).to be_present
    form = document.at_css("form[action='#{user_path(admin)}']")
    expect(form["data-turbo-frame"]).to eq("_top")
    expect(form.at_css("input[name='user[company_ids][]'][value='#{research.id}']")["checked"]).to eq("checked")
    expect(form.at_css("option[value='#{operations.id}']")["selected"]).to eq("selected")
    expect(form.text).to include("must be one of the member companies")
    expect(admin.reload.companies).to contain_exactly(original_company)
    expect(admin.current_company).to eq(original_company)
  end

  it "refreshes the outer role-based menu after the admin changes their own role" do
    get edit_user_path(admin)
    expect(document.at_css('#main-menu [data-item-id="companies"]')).to be_present

    patch user_path(admin), params: { user: {
      super_admin: "0", company_ids: [ "", original_company.id ], current_company_id: original_company.id
    } }, headers: drive_headers

    expect(response).to have_http_status(:see_other)
    follow_redirect!(headers: drive_headers)

    expect(response).to have_http_status(:ok)
    expect(document.at_css("#main-menu")).to be_present
    expect(document.at_css('#main-menu [data-item-id="companies"]')).to be_nil
    expect(admin.reload.super_admin?).to be false
    expect(request.session["warden.user.user.key"].first).to eq([ admin.id ])
  end
end
