# frozen_string_literal: true

require "rails_helper"

# The backdrop is a full-viewport click target at z-30 with pointer-events enabled. It is
# hidden by mobile_nav_controller#close, so shipping it visible meant that on any viewport
# below Tailwind's xl breakpoint (1280px) nothing on the page was clickable until the user
# opened and closed the drawer once.
RSpec.describe "Mobile navigation", type: :request do
  let(:company) { create(:company) }
  let(:user) { ActsAsTenant.with_tenant(company) { create(:user, :super_admin, company: company) } }

  before do
    user.update!(current_company: company)
    sign_in user
    ActsAsTenant.current_tenant = company
  end

  it "renders the backdrop hidden until the drawer is opened" do
    get scans_path

    backdrop = Nokogiri::HTML(response.body).at_css('[data-mobile-nav-target="backdrop"]')

    expect(backdrop).to be_present
    expect(backdrop["class"].split).to include("hidden")
  end

  it "keeps the backdrop suppressed at xl and wider" do
    get scans_path

    backdrop = Nokogiri::HTML(response.body).at_css('[data-mobile-nav-target="backdrop"]')

    expect(backdrop["class"].split).to include("xl:hidden")
  end
end
