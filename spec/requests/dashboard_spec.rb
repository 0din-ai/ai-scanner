# frozen_string_literal: true

require "rails_helper"

# The dashboard is the app's landing page, and until now nothing under spec/requests/
# rendered it: the "Last Five Scans" card's ASR text -- "N/A" for a scan that measured
# nothing, a percentage for one that did -- shipped unverified on the one surface every
# user sees first. A nil avg_successful_attacks regressing back to "0%" here would have
# gone unnoticed by any test.
RSpec.describe "Dashboard", type: :request do
  let(:company) { create(:company) }
  let(:user) { ActsAsTenant.with_tenant(company) { create(:user, :super_admin, company: company) } }

  before do
    user.update!(current_company: company)
    sign_in user
    ActsAsTenant.current_tenant = company
  end

  def last_five_scans_card
    Nokogiri::HTML(response.body).at_xpath(
      "//h3[normalize-space()='Last Five Scans']/ancestor::div[contains(@class,'rounded-lg')][1]"
    )
  end

  it "shows N/A for a scan with no measurable ASR" do
    ActsAsTenant.with_tenant(company) do
      create(:complete_scan, company: company, name: "UnmeasuredScan", avg_successful_attacks: nil)
    end

    get root_path

    card = last_five_scans_card
    expect(card).to be_present
    expect(card.text).to include("UnmeasuredScan")
    expect(card.text).to include("N/A")
  end

  it "shows the rate for a scan with a measured ASR" do
    ActsAsTenant.with_tenant(company) do
      create(:complete_scan, company: company, name: "MeasuredScan", avg_successful_attacks: 73.0)
    end

    get root_path

    card = last_five_scans_card
    expect(card).to be_present
    expect(card.text).to include("MeasuredScan")
    expect(card.text).to include("73%")
    expect(card.text).not_to include("N/A")
  end
end
