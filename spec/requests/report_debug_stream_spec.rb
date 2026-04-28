# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Report debug stream watcher", type: :request do
  let(:company) { create(:company) }
  let(:user) { create(:user, company: company) }
  let(:report) { create(:report, :running, company: company) }
  let(:polling_statuses) { %i[pending starting running processing] }

  before do
    @original_cache_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    sign_in user
  end

  after do
    Rails.cache = @original_cache_store
    ActsAsTenant.current_tenant = nil
  end

  def expect_activity_stream_structure(activity_report, lease_url)
    expect(response.body).to include('id="report-activity-stream"')
    expect(response.body).to include('id="report-activity-stream-summary"')
    expect(response.body).to include('id="report-debug-stream-content"')
    expect(response.body).to include('data-controller="debug-stream-lease"')
    expect(response.body).to include(%(data-debug-stream-lease-url-value="#{lease_url}"))
    expect(response.body).to include('data-debug-stream-lease-interval-value="30000"')
    expect(response.body).to include(%(signed-stream-name="#{debug_stream_name_for(activity_report)}"))
  end

  def expect_no_activity_stream
    expect(response.body).not_to include("report-activity-stream")
    expect(response.body).not_to include("report-activity-stream-summary")
    expect(response.body).not_to include("report-debug-stream-content")
    expect(response.body).not_to include('data-controller="debug-stream-lease"')
  end

  def expect_static_activity_stream(activity_report)
    expect(response.body).to include('id="report-activity-stream"')
    expect(response.body).to include('id="report-activity-stream-summary"')
    expect(response.body).to include('id="report-debug-stream-content"')
    expect(response.body).not_to include('data-controller="debug-stream-lease"')
    expect(response.body).not_to include(%(signed-stream-name="#{debug_stream_name_for(activity_report)}"))
  end

  def debug_stream_name_for(activity_report)
    Turbo::StreamsChannel.signed_stream_name(Reports::DebugWatcher.stream_name(activity_report))
  end

  it "renders the admin Activity Stream without starting polling from the report view" do
    expect {
      get report_path(report)
    }.not_to have_enqueued_job(BroadcastReportDebugJob)

    expect(response).to have_http_status(:ok)
    expect(Reports::DebugWatcher.watching?(report.id)).to be(false)
    expect_activity_stream_structure(report, refresh_debug_lease_report_path(report))
  end

  it "refreshes the watcher lease from the admin keepalive endpoint for polling reports" do
    polling_statuses.each do |status|
      polling_report = create(:report, company: company, status: status)

      expect {
        post refresh_debug_lease_report_path(polling_report)
      }.to have_enqueued_job(BroadcastReportDebugJob).with(polling_report.id)

      expect(response).to have_http_status(:ok)
      expect(Reports::DebugWatcher.watching?(polling_report.id)).to be(true)
    end
  end

  it "rejects unauthenticated admin keepalive requests" do
    sign_out user

    expect {
      post refresh_debug_lease_report_path(report)
    }.not_to have_enqueued_job(BroadcastReportDebugJob)

    expect(response).to redirect_to(new_user_session_path)
    expect(Reports::DebugWatcher.watching?(report.id)).to be(false)
  end

  it "does not refresh an admin watcher lease for another company report" do
    other_report = create(:report, :running, company: create(:company))

    expect {
      post refresh_debug_lease_report_path(other_report)
    }.not_to have_enqueued_job(BroadcastReportDebugJob)

    expect(response).to have_http_status(:not_found)
    expect(Reports::DebugWatcher.watching?(other_report.id)).to be(false)
  end

  it "refreshes the admin watcher lease without polling terminal reports" do
    completed_report = create(:report, :completed, company: company)

    expect {
      post refresh_debug_lease_report_path(completed_report)
    }.not_to have_enqueued_job(BroadcastReportDebugJob)

    expect(response).to have_http_status(:ok)
    expect(Reports::DebugWatcher.watching?(completed_report.id)).to be(true)
  end

  it "does not render the admin Activity Stream for terminal reports without debug fallback" do
    completed_report = create(:report, :completed, company: company)

    expect {
      get report_path(completed_report)
    }.not_to have_enqueued_job(BroadcastReportDebugJob)

    expect(response).to have_http_status(:ok)
    expect(Reports::DebugWatcher.watching?(completed_report.id)).to be(false)
    expect_no_activity_stream
  end

  it "renders the admin terminal-report debug fallback without mounting a watcher lease" do
    completed_report = create(:report, :completed, company: company)

    expect {
      get report_path(completed_report), params: { debug: "true" }
    }.not_to have_enqueued_job(BroadcastReportDebugJob)

    expect(response).to have_http_status(:ok)
    expect(Reports::DebugWatcher.watching?(completed_report.id)).to be(false)
    expect_static_activity_stream(completed_report)
  end

  it "renders the admin Activity Stream with live tail logs" do
    create(
      :report_debug_log,
      report: report,
      tail: "admin live tail line\n",
      tail_offset: 128,
      tail_digest: "admin-tail"
    )

    get report_path(report)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("report-debug-stream-content")
    expect(response.body).to include("turbo-cable-stream-source")
    expect(response.body).to include("Live tail")
    expect(response.body).to include("admin live tail line")
  end

  it "renders the report details Activity Stream without starting polling from the report view" do
    expect {
      get report_detail_path(report)
    }.not_to have_enqueued_job(BroadcastReportDebugJob)

    expect(response).to have_http_status(:ok)
    expect(Reports::DebugWatcher.watching?(report.id)).to be(false)
    expect_activity_stream_structure(report, refresh_debug_lease_report_detail_path(report))
  end

  it "refreshes the watcher lease from the report details keepalive endpoint for polling reports" do
    polling_statuses.each do |status|
      polling_report = create(:report, company: company, status: status)

      expect {
        post refresh_debug_lease_report_detail_path(polling_report)
      }.to have_enqueued_job(BroadcastReportDebugJob).with(polling_report.id)

      expect(response).to have_http_status(:ok)
      expect(Reports::DebugWatcher.watching?(polling_report.id)).to be(true)
    end
  end

  it "rejects unauthenticated report-details keepalive requests" do
    sign_out user

    expect {
      post refresh_debug_lease_report_detail_path(report)
    }.not_to have_enqueued_job(BroadcastReportDebugJob)

    expect(response).to redirect_to(new_user_session_path)
    expect(Reports::DebugWatcher.watching?(report.id)).to be(false)
  end

  it "does not refresh a report-details watcher lease for another company report" do
    other_report = create(:report, :running, company: create(:company))

    expect {
      post refresh_debug_lease_report_detail_path(other_report)
    }.not_to have_enqueued_job(BroadcastReportDebugJob)

    expect(response).to have_http_status(:not_found)
    expect(Reports::DebugWatcher.watching?(other_report.id)).to be(false)
  end

  it "renders the report details Activity Stream with live tail logs" do
    create(
      :report_debug_log,
      report: report,
      tail: "details live tail line\n",
      tail_offset: 256,
      tail_digest: "details-tail"
    )

    get report_detail_path(report)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("report-debug-stream-content")
    expect(response.body).to include('data-controller="debug-tabs debug-stream-filter"')
    expect(response.body).to include('data-action="click->debug-tabs#switch"')
    expect(response.body).to include("Live tail")
    expect(response.body).to include("details live tail line")
  end

  it "does not start report-details polling in PDF mode" do
    expect {
      get report_detail_path(report), params: { debug: "true", pdf: "true" }
    }.not_to have_enqueued_job(BroadcastReportDebugJob)

    expect(response).to have_http_status(:ok)
    expect(Reports::DebugWatcher.watching?(report.id)).to be(false)
    expect_no_activity_stream
  end

  it "renders the report-details terminal-report debug fallback without mounting a watcher lease" do
    completed_report = create(:report, :completed, company: company)

    expect {
      get report_detail_path(completed_report), params: { debug: "true" }
    }.not_to have_enqueued_job(BroadcastReportDebugJob)

    expect(response).to have_http_status(:ok)
    expect(Reports::DebugWatcher.watching?(completed_report.id)).to be(false)
    expect_static_activity_stream(completed_report)
  end
end
