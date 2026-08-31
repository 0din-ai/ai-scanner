# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Report JSON export", type: :request do
  let(:company) { create(:company) }
  let(:user) { create(:user, :super_admin, company: company) }
  let(:target) { ActsAsTenant.with_tenant(company) { create(:target, company: company) } }
  let(:report) do
    ActsAsTenant.with_tenant(company) { create(:report, :completed, company: company, target: target) }
  end

  before do
    user.update!(current_company: company)
    sign_in user
    ActsAsTenant.current_tenant = company
  end

  def seed_attempt
    ActsAsTenant.with_tenant(company) do
      create(:probe_result, report: report, probe: create(:probe, name: "Export probe"),
             attempts: [ { "uuid" => "a", "prompt" => "how is it made", "outputs" => [ "no" ],
                           "attack_succeeded" => true } ])
    end
  end

  it "downloads the report as parseable JSON" do
    seed_attempt

    get json_export_report_path(report)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    doc = JSON.parse(response.body)
    expect(doc["runs"].first["probe_results"].first["attempts"].first["prompt"]).to eq("how is it made")
  end

  it "offers the file as a download named for the report" do
    seed_attempt

    get json_export_report_path(report)

    expect(response.headers["Content-Disposition"]).to include("attachment")
    expect(response.headers["Content-Disposition"]).to include(report.uuid)
  end

  it "sends a complete body with a length rather than an open-ended stream" do
    # The export is buffered before any header goes out. Streaming would commit a
    # 200 with the first chunk, before a single probe_result had been read, so a
    # failure part-way through would hand the reader a truncated file that still
    # looked like a successful download.
    seed_attempt

    get json_export_report_path(report)

    expect(response.headers["Content-Length"].to_i).to eq(response.body.bytesize)
    expect(response.headers["Content-Length"].to_i).to be > 0
  end

  it "tells caches not to keep it" do
    # The file carries prompts and model responses.
    seed_attempt

    get json_export_report_path(report)

    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "leaves no spool file behind" do
    seed_attempt
    before_count = Dir.glob(File.join(Dir.tmpdir, "report_export*.json")).size

    get json_export_report_path(report)
    response.body

    expect(Dir.glob(File.join(Dir.tmpdir, "report_export*.json")).size).to eq(before_count)
  end

  it "404s for a report in another tenant" do
    other_company = create(:company)
    foreign = ActsAsTenant.with_tenant(other_company) do
      t = create(:target, company: other_company)
      create(:report, :completed, company: other_company, target: t)
    end

    get json_export_report_path(foreign)

    expect(response).to have_http_status(:not_found)
    # Not served as a download, and not a JSON body: the other tenant's report
    # is simply not reachable from here.
    expect(response.headers["Content-Disposition"]).to be_nil
    expect(response.media_type).not_to eq("application/json")
  end

  it "redirects an anonymous visitor to sign in" do
    sign_out user

    get json_export_report_path(report)

    expect(response).to have_http_status(:found)
    expect(response.location).to include("/login")
  end

  it "offers the button on a report with results" do
    seed_attempt

    get report_path(report)

    expect(response.body).to include("Export to JSON")
    expect(response.body).to include(json_export_report_path(report))
  end
end
