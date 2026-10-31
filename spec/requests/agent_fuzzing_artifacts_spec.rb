# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Agent assessment sources and receipts", type: :request do
  let(:company) { create(:company) }
  let(:scan) { create(:complete_scan, company: company, agent_fuzzing: true) }
  let(:report) { create(:report, scan: scan, company: company, target: scan.targets.first, status: :running, execution_token: SecureRandom.uuid) }
  let(:run) { AgentFuzzingRun.create!(company: company, scan: scan, target: report.target, source_report: report, status: :running, execution_token: report.execution_token) }
  let(:source_token) { SecureRandom.urlsafe_base64(32) }
  let(:receipt_token) { SecureRandom.urlsafe_base64(32) }
  let!(:artifact) do
    ActsAsTenant.with_tenant(company) do
      AgentFuzzingArtifact.create!(company: company, agent_fuzzing_run: run, trial_id: SecureRandom.uuid,
        arm: "attack", source_digest: Digest::SHA256.hexdigest(source_token),
        receipt_digest: Digest::SHA256.hexdigest(receipt_token), body: "inert fixture document",
        body_sha256: Digest::SHA256.hexdigest("inert fixture document"), expires_at: 5.minutes.from_now)
    end
  end

  it "separates source exposure from subsequent downstream receipts without a login" do
    ActsAsTenant.current_tenant = nil
    post "/agent-artifacts/receipt", params: { token: receipt_token }
    expect(response).to have_http_status(:not_found)
    head "/agent-artifacts/source", params: { token: source_token }
    expect(artifact.reload.source_reads).to eq(0)
    get "/agent-artifacts/source", params: { token: source_token }
    expect(response.body).to eq("inert fixture document")
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(artifact.reload.source_reads).to eq(1)
    expect(artifact.receipt_count).to eq(0)
    post "/agent-artifacts/receipt", params: { token: receipt_token }
    expect(response).to have_http_status(:no_content)
    expect(artifact.reload.receipt_count).to eq(1)
    expect(artifact.receipt_at).to be >= artifact.source_read_at
  end

  it "ignores GET probes so link previews cannot forge a callback" do
    get "/agent-artifacts/receipt", params: { token: receipt_token }
    expect(response).to have_http_status(:not_found)
    expect(artifact.reload.receipt_count).to eq(0)
  end

  it "rejects the wrong capability purpose and expired or closed sources" do
    get "/agent-artifacts/source", params: { token: receipt_token }
    expect(response).to have_http_status(:not_found)
    artifact.update!(expires_at: 1.second.ago)
    get "/agent-artifacts/source", params: { token: source_token }
    expect(response).to have_http_status(:not_found)
    artifact.update!(expires_at: 1.minute.from_now, closed_at: Time.current)
    get "/agent-artifacts/source", params: { token: source_token }
    expect(response).to have_http_status(:not_found)
  end

  it "revokes access when the primary report is cancelled or replaced" do
    report.update_columns(execution_token: SecureRandom.uuid)
    get "/agent-artifacts/source", params: { token: source_token }
    expect(response).to have_http_status(:not_found)
    report.update_columns(status: Report.statuses[:stopped], execution_token: nil)
    get "/agent-artifacts/source", params: { token: source_token }
    expect(response).to have_http_status(:not_found)
  end
end
