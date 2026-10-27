require "rails_helper"

RSpec.describe "User password updates", type: :request do
  let(:company) { create(:company) }
  let(:admin) { create(:user, :super_admin, company: company) }
  let(:member) { create(:user, company: company) }
  let(:new_password) { "changed-password123" }
  let(:frame_headers) do
    { "Turbo-Frame" => "main-content", "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" }
  end

  def log_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
    expect(response).to redirect_to(root_path)
  end

  def password_attributes
    { password: new_password, password_confirmation: new_password, time_zone: "Madrid" }
  end

  def expect_profile_frame(user)
    expect(response).to have_http_status(:ok)
    frame = Nokogiri::HTML(response.body).at_css("turbo-frame#main-content")
    expect(frame).to be_present
    expect(frame.text).to include(user.email)
  end

  [ :admin, :member ].each do |role|
    it "keeps the #{role} authenticated through a Turbo self-password update and redirect" do
      user = public_send(role)
      log_in(user)
      attributes = password_attributes
      if user.super_admin?
        attributes = attributes.merge(company_ids: [ "", company.id ], current_company_id: company.id)
      end

      patch user_path(user), params: { user: attributes }, headers: frame_headers

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(user_path(user))
      expect(user.reload.valid_password?(new_password)).to be true
      expect(user.time_zone).to eq("Madrid")
      follow_redirect!(headers: frame_headers)
      expect_profile_frame(user)
      expect(request.session["warden.user.user.key"].first).to eq([ user.id ])

      get edit_user_path(user)
      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).at_css("input#user_email")["value"]).to eq(user.email)
    end
  end

  it "keeps the admin identity when changing another user's password" do
    log_in(admin)

    patch user_path(member), params: { user: password_attributes }, headers: frame_headers

    expect(response).to have_http_status(:see_other)
    expect(member.reload.valid_password?(new_password)).to be true
    follow_redirect!(headers: frame_headers)
    expect_profile_frame(member)
    expect(request.session["warden.user.user.key"].first).to eq([ admin.id ])
    get companies_path
    expect(response).to have_http_status(:ok)
  end

  it "preserves the actual admin session when an impersonated user changes their password" do
    log_in(admin)
    post impersonation_path, params: { id: member.id }
    expect(response).to redirect_to(root_path)

    patch user_path(member), params: { user: password_attributes }, headers: frame_headers

    expect(response).to have_http_status(:see_other)
    expect(member.reload.valid_password?(new_password)).to be true
    follow_redirect!(headers: frame_headers)
    expect_profile_frame(member)
    expect(request.session["warden.user.user.key"].first).to eq([ admin.id ])
    expect(request.session[:admin_user_id]).to eq(admin.id)
    expect(request.session[:impersonated_user_id]).to eq(member.id)

    delete impersonation_path
    expect(response).to redirect_to(users_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(request.session["warden.user.user.key"].first).to eq([ admin.id ])
    expect(request.session[:impersonated_user_id]).to be_nil
    get companies_path
    expect(response).to have_http_status(:ok)
  end

  it "keeps the original password and authenticated session after failed validation" do
    log_in(member)
    attributes = password_attributes.merge(password_confirmation: "does-not-match")

    patch user_path(member), params: { user: attributes }, headers: frame_headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(Nokogiri::HTML(response.body).at_css("turbo-frame#main-content")).to be_present
    expect(member.reload.valid_password?("password123")).to be true
    get user_path(member), headers: frame_headers
    expect_profile_frame(member)
    expect(request.session["warden.user.user.key"].first).to eq([ member.id ])
  end
end
