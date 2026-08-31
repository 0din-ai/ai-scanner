# frozen_string_literal: true

require "rails_helper"

# The evidence list is a table of links; the drawer is what a reader actually reads.
# These cover the boundary between them -- the indexes and ids the list hands over,
# and what happens when a hand-edited URL hands over something else.
RSpec.describe "Report evidence", type: :request do
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

  # The evidence tab always requests its own frame; only a pasted URL arrives
  # without this header, and that is redirected to the report page.
  def get_frame(path)
    get path, headers: { "Turbo-Frame" => "report-evidence-tab" }
  end

  def probe_result_with(attempts, on: report, probe_name: "Probe A")
    ActsAsTenant.with_tenant(company) do
      create(:probe_result, report: on, probe: create(:probe, name: probe_name), attempts: attempts)
    end
  end

  describe "GET /reports/:id/evidence" do
    it "lists an attempt with its outcome" do
      probe_result_with([ { "uuid" => "a", "prompt" => "how is ricin made", "outputs" => [ "no" ],
                            "attack_succeeded" => true } ])

      get_frame evidence_report_path(report)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("how is ricin made")
    end

    it "keeps All selected when the filter is junk rather than showing an empty table" do
      probe_result_with([ { "uuid" => "a", "prompt" => "q", "outputs" => [ "x" ], "attack_succeeded" => true } ])

      get_frame evidence_report_path(report, filter: "'; DROP TABLE--")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("q")
    end

    it "clamps a page past the end onto the last one" do
      attempts = Array.new(30) { |i| { "uuid" => "u#{i}", "prompt" => "attempt #{i}", "outputs" => [ "x" ] } }
      probe_result_with(attempts)

      get_frame evidence_report_path(report, page: 9999)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("attempt 29")
    end

    it "clamps a nonsense page onto the first one" do
      probe_result_with([ { "uuid" => "a", "prompt" => "only attempt", "outputs" => [ "x" ] } ])

      get_frame evidence_report_path(report, page: "-4")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("only attempt")
    end

    it "sends a pasted deep link to the report page instead of a bare frame" do
      # This action answers a lazy frame, so it renders without a layout: no
      # importmap, no Stimulus. Served straight to the address bar it was a dead
      # fragment -- the server had resolved the attempt and nothing could open it.
      probe_result_with([ { "uuid" => "a", "prompt" => "q", "outputs" => [ "x" ] } ])
      pr = ProbeResult.last

      get evidence_report_path(report, probe_result_id: pr.id, attempt_index: 0)

      expect(response).to have_http_status(:found)
      expect(response.location).to include("/reports/#{report.id}")
      expect(response.location).to include("tab=evidence")
      expect(response.location).to include("probe_result_id=#{pr.id}")
      expect(response.location).to include("attempt_index=0")
    end

    it "still renders the frame body for the tab's own request" do
      probe_result_with([ { "uuid" => "a", "prompt" => "framed attempt", "outputs" => [ "x" ] } ])

      get_frame evidence_report_path(report)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("framed attempt")
      expect(response.body).not_to include("<!DOCTYPE html>")
    end

    it "carries the deep link into the frame url on the report page" do
      probe_result_with([ { "uuid" => "a", "prompt" => "q", "outputs" => [ "x" ] } ])
      pr = ProbeResult.last

      get report_path(report, tab: "evidence", probe_result_id: pr.id, attempt_index: 0)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-report-redesigned-initial-tab-value=\"evidence\"")
      expect(response.body).to include("probe_result_id=#{pr.id}")
    end

    it "includes a variant child's attempts alongside the parent's" do
      probe_result_with([ { "uuid" => "parent", "prompt" => "parent attempt", "outputs" => [ "x" ] } ])
      ActsAsTenant.with_tenant(company) do
        child = create(:report, :completed, company: company, target: target,
                       parent_report: report)
        probe_result_with([ { "uuid" => "child", "prompt" => "variant attempt", "outputs" => [ "x" ] } ],
                          on: child, probe_name: "Probe B")
      end

      get_frame evidence_report_path(report.reload)

      expect(response.body).to include("parent attempt")
      expect(response.body).to include("variant attempt")
    end
  end

  describe "the variant badge" do
    # The badge claims the attempt is a threat variant of the probe, so it has to
    # follow threat_variant_id. Following "came from the child report" instead was
    # wrong from both directions.
    it "badges a threat-variant attempt when the variant report is opened on its own" do
      ActsAsTenant.with_tenant(company) do
        child = create(:report, :completed, company: company, target: target, parent_report: report)
        variant = create(:threat_variant)
        create(:probe_result, report: child, probe: create(:probe, name: "Probe V"),
               threat_variant_id: variant.id,
               attempts: [ { "uuid" => "v", "prompt" => "variant attempt", "outputs" => [ "x" ] } ])

        rows = Reports::EvidenceRows.new(child.reload).rows
        expect(rows.map(&:variant)).to eq([ true ])
      end
    end

    it "does not badge a child attempt that resolved no variant" do
      ActsAsTenant.with_tenant(company) do
        child = create(:report, :completed, company: company, target: target, parent_report: report)
        create(:probe_result, report: child, probe: create(:probe, name: "Probe W"),
               threat_variant_id: nil,
               attempts: [ { "uuid" => "n", "prompt" => "plain attempt", "outputs" => [ "x" ] } ])
      end

      rows = Reports::EvidenceRows.new(report.reload).rows
      expect(rows.map(&:variant)).to eq([ false ])
    end
  end

  describe "GET /reports/:id/evidence_attempt" do
    let!(:probe_result) do
      probe_result_with([
        { "uuid" => "a", "prompt" => "the question", "outputs" => [ "first answer", "second answer" ],
          "attack_succeeded" => true, "detector_scores" => { "dan.DAN" => 1.0 } }
      ])
    end

    it "renders every generation, not only the one that decided the verdict" do
      # The verdict is the max across generations, so the deciding output is often not
      # the first. Showing one would let a reader conclude the run was clean.
      get evidence_attempt_report_path(report, probe_result_id: probe_result.id, attempt_index: 0)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("first answer")
      expect(response.body).to include("second answer")
    end

    it "shows the text of a malformed hash output that search can match" do
      # The list and the drawer read the same field through different engines. SQL
      # treats a bare hash as one output; Kernel#Array turns it into key/value
      # pairs, which rendered an empty panel under a search hit that matched.
      odd = probe_result_with([ { "uuid" => "b", "prompt" => "q",
                                  "outputs" => { "text" => "the matched phrase" } } ],
                              probe_name: "Probe F")

      expect(Reports::EvidenceRows.new(report.reload, query: "the matched phrase").rows.size).to eq(1)

      get evidence_attempt_report_path(report, probe_result_id: odd.id, attempt_index: 0)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("the matched phrase")
    end

    it "rejects a non-numeric index" do
      get evidence_attempt_report_path(report, probe_result_id: probe_result.id, attempt_index: "abc")

      expect(response).to have_http_status(:bad_request)
    end

    it "404s past the end of the stored array" do
      get evidence_attempt_report_path(report, probe_result_id: probe_result.id, attempt_index: 999)

      expect(response).to have_http_status(:not_found)
    end

    it "404s for a probe result belonging to another report" do
      other = ActsAsTenant.with_tenant(company) do
        create(:report, :completed, company: company, target: target)
      end
      foreign = probe_result_with([ { "uuid" => "x", "prompt" => "theirs", "outputs" => [ "y" ] } ],
                                  on: other, probe_name: "Probe C")

      get evidence_attempt_report_path(report, probe_result_id: foreign.id, attempt_index: 0)

      expect(response).to have_http_status(:not_found)
    end

    it "404s for a probe result in another tenant" do
      other_company = create(:company)
      foreign = ActsAsTenant.with_tenant(other_company) do
        t = create(:target, company: other_company)
        r = create(:report, :completed, company: other_company, target: t)
        create(:probe_result, report: r, probe: create(:probe, name: "Probe D"),
               attempts: [ { "uuid" => "x", "prompt" => "theirs", "outputs" => [ "y" ] } ])
      end

      get evidence_attempt_report_path(report, probe_result_id: foreign.id, attempt_index: 0)

      expect(response).to have_http_status(:not_found)
    end

    it "says so plainly when a scan predates detector capture" do
      # Forward-only: older reports kept the verdict but not the scores behind it.
      # Silence would read as "no detector fired", which is a different claim.
      older = probe_result_with([ { "uuid" => "b", "prompt" => "q", "outputs" => [ "x" ],
                                    "attack_succeeded" => true } ], probe_name: "Probe E")

      get evidence_attempt_report_path(report, probe_result_id: older.id, attempt_index: 0)

      expect(response.body).to include("wasn't recorded for this attempt")
    end
  end
end
