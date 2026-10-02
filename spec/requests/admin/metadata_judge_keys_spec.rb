# frozen_string_literal: true

require "rails_helper"

# The judge's settings are written only through the Settings page, which validates them
# as one unit. The generic metadata CRUD must refuse them for every actor -- super admins
# included -- or it becomes a second, unvalidated writer.
RSpec.describe "Metadata: judge keys", type: :request do
  let(:company) { create(:company) }
  let(:super_admin) { create(:user, :super_admin, company: company) }

  before do
    SettingsService.clear_cache
    super_admin.update!(current_company: company)
    sign_in super_admin
    ActsAsTenant.current_tenant = company
  end

  it "refuses a super admin creating a judge_* key" do
    expect {
      post metadata_path, params: { metadatum: { key: "judge_enabled", value: "true" } }
    }.not_to change(Metadatum, :count)
    expect(flash[:alert]).to eq("Not authorized.")
  end

  it "refuses a super admin updating a judge_* key" do
    row = Metadatum.create!(key: "judge_model_name", value: "safe-model")

    patch metadatum_path(row), params: { metadatum: { key: "judge_model_name", value: "other" } }

    expect(row.reload.value).to eq("safe-model")
  end

  it "refuses renaming an ordinary key into the judge namespace" do
    row = Metadatum.create!(key: "harmless", value: "true")

    patch metadatum_path(row), params: { metadatum: { key: "judge_enabled", value: "true" } }

    expect(row.reload.key).to eq("harmless")
  end

  it "refuses a super admin destroying a judge_* key" do
    row = Metadatum.create!(key: "judge_enabled", value: "true")

    expect { delete metadatum_path(row) }.not_to change(Metadatum, :count)
  end

  it "still lets a super admin manage ordinary keys" do
    post metadata_path, params: { metadatum: { key: "harmless", value: "1" } }

    expect(Metadatum.find_by(key: "harmless")&.value).to eq("1")
  end

  it "hides judge_* rows from a member's index and show" do
    row = Metadatum.create!(key: "judge_model_name", value: "hidden-model")
    Metadatum.create!(key: "visible_key", value: "shown-value")
    member = create(:user, company: company)
    member.update!(current_company: company)
    sign_in member

    get metadata_path
    expect(response.body).to include("visible_key")
    expect(response.body).not_to include("hidden-model")

    get metadatum_path(row)
    expect(response.body).not_to include("hidden-model")
  end
end
