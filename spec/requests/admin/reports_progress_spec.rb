# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GET /reports/:id/progress", type: :request do
  let(:company) { create(:company) }
  let(:user) { create(:user, :super_admin, company: company) }
  let(:report) do
    ActsAsTenant.with_tenant(company) { create(:report, company: company, status: :running) }
  end

  before do
    user.update!(current_company: company)
    sign_in user
    ActsAsTenant.current_tenant = company
  end

  it "renders the progress body for a run in flight" do
    ActsAsTenant.with_tenant(company) { report.update_columns(pid: 1, heartbeat_at: Time.current) }

    get progress_report_path(report)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Running")
    expect(response.body).not_to include("<!DOCTYPE html>")
  end

  it "answers 304 when the derived representation has not changed" do
    ActsAsTenant.with_tenant(company) { report.update_columns(pid: 1, heartbeat_at: Time.current) }

    get progress_report_path(report)
    etag = response.headers["ETag"]
    expect(etag).to be_present

    get progress_report_path(report), headers: { "HTTP_IF_NONE_MATCH" => etag }

    # The point of the conditional response: a matching etag skips the journal read,
    # which is the expensive half of answering.
    expect(response).to have_http_status(:not_modified)
  end

  it "re-renders when the representation changes even though the row did not" do
    # Crossing the stall threshold writes nothing to the database, so an etag derived
    # from updated_at would serve the same card indefinitely.
    ActsAsTenant.with_tenant(company) { report.update_columns(pid: 1, heartbeat_at: Time.current) }
    get progress_report_path(report)
    etag = response.headers["ETag"]

    ActsAsTenant.with_tenant(company) { report.update_columns(heartbeat_at: 1.hour.ago) }

    get progress_report_path(report), headers: { "HTTP_IF_NONE_MATCH" => etag }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Not responding")
  end

  it "tells the client to stop polling once the run has finished" do
    ActsAsTenant.with_tenant(company) { report.update!(status: :completed) }

    get progress_report_path(report)

    expect(response.body).to include('data-poll="false"')
  end
end
