# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::ScansController, type: :controller do
  render_views

  let!(:company) { create(:company, tier: :tier_4) }
  let!(:super_admin) { create(:user, :super_admin, company: company) }
  let!(:target) { ActsAsTenant.with_tenant(company) { create(:target, company: company) } }
  let!(:probe) { create(:probe) }
  let!(:scan) do
    ActsAsTenant.with_tenant(company) do
      create(:complete_scan, company: company)
    end
  end

  before do
    super_admin.update!(current_company: company)
    sign_in super_admin
    ActsAsTenant.current_tenant = company
  end

  describe "the probe breakdown" do
    # Groups previously showed only "N probes", so two detectors sharing a friendly name
    # produced two rows reading identically with no way to see what was in either.
    it "names each probe in the group and links it to its detail page" do
      odin = create(:detector, name: "0din.MitigationBypass")
      alpha = create(:probe, name: "AlphaProbe", detector: odin)
      beta = create(:probe, name: "BetaProbe", detector: odin)
      ActsAsTenant.with_tenant(company) { scan.probes = [ alpha, beta ] }

      get :show, params: { id: scan.id }

      doc = Nokogiri::HTML(response.body)
      expect(doc.css("a[href='#{probe_path(alpha)}']")).to be_present
      expect(doc.css("a[href='#{probe_path(beta)}']")).to be_present
    end

    it "does not link a probe the viewer is not authorized to open" do
      # A saved scan keeps probes that a later sync disables, but ProbePolicy#show? denies
      # those to anyone who is not a super admin, so linking one offers navigation that
      # bounces off Pundit. Historical probes stay visible, just not linked.
      member = create(:user, company: company)
      member.update!(current_company: company)
      sign_in member

      odin = create(:detector, name: "0din.MitigationBypass")
      live = create(:probe, name: "LiveProbe", detector: odin)
      retired = create(:probe, name: "RetiredProbe", detector: odin, enabled: false)
      ActsAsTenant.with_tenant(company) { scan.probes = [ live, retired ] }

      get :show, params: { id: scan.id }

      doc = Nokogiri::HTML(response.body)
      expect(doc.css("a[href='#{probe_path(live)}']")).to be_present
      expect(doc.css("a[href='#{probe_path(retired)}']")).to be_empty
      expect(response.body).to include("RetiredProbe")
    end

    it "qualifies groups whose friendly names collide" do
      odin = create(:detector, name: "0din.MitigationBypass")
      upstream = create(:detector, name: "mitigation.MitigationBypass")
      ActsAsTenant.with_tenant(company) do
        scan.probes = [ create(:probe, name: "FromOdin", detector: odin),
                        create(:probe, name: "FromUpstream", detector: upstream) ]
      end

      get :show, params: { id: scan.id }

      expect(response.body).to include("0din.MitigationBypass")
      expect(response.body).to include("mitigation.MitigationBypass")
    end
  end

  describe "GET #index" do
    it "returns success" do
      get :index
      expect(response).to have_http_status(:success)
    end

    describe "the default filter" do
      # The default scope was `scheduled`, so a company whose scans are all one-time saw
      # "No scans found" beside a tab reading All: 126. The counts were right; the list
      # was filtered to a scope nothing matched.
      def active_tab
        doc = Nokogiri::HTML(response.body)
        link = doc.css("a").find { |a| a["class"].to_s.include?("text-primary") && a["href"].to_s.include?("scope=") }
        link && link["href"][/scope=(\w+)/, 1]
      end

      let!(:one_time) do
        ActsAsTenant.with_tenant(company) do
          create(:complete_scan, company: company, name: "OneTimeAlpha")
        end
      end

      it "shows existing scans when no filter is given" do
        get :index

        expect(response.body).to include("OneTimeAlpha")
        expect(response.body).not_to include("No scans found")
      end

      it "marks All as the active tab" do
        get :index

        expect(active_tab).to eq("all")
      end

      it "still shows the empty state for a company with no scans at all" do
        ActsAsTenant.with_tenant(company) { Scan.find_each(&:destroy) }

        get :index

        expect(response.body).to include("No scans found")
      end
    end

    describe "explicit filters" do
      # Deterministic names: the shared `scan` fixture takes a Faker name, which can occur
      # in the page's own chrome and make an include-assertion pass regardless of filter.
      let!(:one_time) do
        ActsAsTenant.with_tenant(company) do
          create(:complete_scan, company: company, name: "OneTimeAlpha")
        end
      end

      let!(:scheduled) do
        ActsAsTenant.with_tenant(company) do
          create(:complete_scan, :with_recurrence, company: company, name: "ScheduledAlpha")
        end
      end

      it "still honours an explicit scheduled filter" do
        get :index, params: { scope: "scheduled" }

        expect(response.body).to include("ScheduledAlpha")
        expect(response.body).not_to include("OneTimeAlpha")
      end

      it "still honours an explicit one-time filter" do
        get :index, params: { scope: "unscheduled" }

        expect(response.body).to include("OneTimeAlpha")
        expect(response.body).not_to include("ScheduledAlpha")
      end

      it "carries the filter through pagination links" do
        # A filter that survives the first page but not the second sends the reader back
        # to an unfiltered list without saying so.
        ActsAsTenant.with_tenant(company) { create_list(:complete_scan, 40, company: company) }

        get :index, params: { scope: "unscheduled" }

        pagination_links = Nokogiri::HTML(response.body).css("nav a").map { |a| a["href"].to_s }
        paged = pagination_links.select { |href| href.include?("page=") }
        expect(paged).not_to be_empty
        expect(paged).to all(include("scope=unscheduled"))
      end

      it "treats an unrecognised scope as All rather than showing nothing" do
        get :index, params: { scope: "nonsense" }

        expect(response.body).to include("OneTimeAlpha")
        expect(response.body).to include("ScheduledAlpha")
      end
    end

    describe "sorting by avg_successful_attacks" do
      # avg_successful_attacks is nullable -- a scan whose reports measured nothing has no
      # rate. Postgres puts NULLs first on ORDER BY ... DESC by default, so sorting "worst
      # ASR first" led with unmeasured scans ahead of every measured rate. Mirrors
      # Admin::ProbesController's NULLS LAST handling for success_rate_calculated.
      let!(:unmeasured) do
        ActsAsTenant.with_tenant(company) do
          create(:complete_scan, company: company, name: "UnmeasuredAlpha", avg_successful_attacks: nil)
        end
      end

      let!(:measured) do
        ActsAsTenant.with_tenant(company) do
          create(:complete_scan, company: company, name: "MeasuredAlpha", avg_successful_attacks: 42.0)
        end
      end

      it "puts the unmeasured scan last when sorting ASR descending" do
        get :index, params: { q: { s: "avg_successful_attacks desc" } }

        expect(response.body.index("MeasuredAlpha")).to be < response.body.index("UnmeasuredAlpha")
      end

      it "puts the unmeasured scan last when sorting ASR ascending too" do
        get :index, params: { q: { s: "avg_successful_attacks asc" } }

        expect(response.body.index("MeasuredAlpha")).to be < response.body.index("UnmeasuredAlpha")
      end
    end

    it "does not render the empty state for a company with a long scan history" do
      # The reported case: 126 existing scans, none scheduled.
      ActsAsTenant.with_tenant(company) { create_list(:complete_scan, 126, company: company) }

      get :index

      expect(response.body).not_to include("No scans found")
    end

    it "renders the index template" do
      get :index
      expect(response.body).to include("Scans")
    end

    it "supports scope filtering" do
      get :index, params: { scope: "all" }
      expect(response).to have_http_status(:success)
    end

    it "renders labeled, hover-reveal action buttons" do
      get :index, params: { scope: "all" }

      assert_select "a[href=?]", reports_path(q: { scan_id_eq: scan.id }), text: /Reports/
      assert_select "tbody tr.group"
      expect(response.body).to include("group-hover:opacity-100")
      expect(response.body).to include("group-focus-within:opacity-100")
    end

    it "exposes a single 'New Scan' creation action on the populated view" do
      get :index

      assert_select "a[href=?]", new_scan_path, text: /\ANew Scan\z/, count: 1
    end

    context "when there are no scans" do
      before { ActsAsTenant.with_tenant(company) { Scan.destroy_all } }

      it "shows the empty-state guidance message" do
        get :index

        expect(response.body).to include("No scans found")
      end

      it "exposes exactly one 'New Scan' creation action pointing at /scans/new" do
        get :index

        assert_select "a[href=?]", new_scan_path, text: /\ANew Scan\z/, count: 1
      end

      it "does not render the duplicate 'Create Scan' action" do
        get :index

        expect(response.body).not_to include("Create Scan")
      end
    end

    context "when quota is exhausted" do
      before do
        allow_any_instance_of(Company).to receive(:scan_allowed?).and_return(false)
      end

      it "does not show the header 'New Scan' action" do
        get :index

        doc = Nokogiri::HTML(response.body)
        header = doc.at_css("#custom-page-header")

        expect(header.css("a[href='#{new_scan_path}']").select { |node| node.text.squish == "New Scan" }).to be_empty
      end

      context "and there are no scans" do
        before { ActsAsTenant.with_tenant(company) { Scan.destroy_all } }

        it "shows exactly one 'New Scan' action in the empty state so scheduled creation stays reachable" do
          get :index

          doc = Nokogiri::HTML(response.body)
          creation_links = doc.css("a[href='#{new_scan_path}']").select { |node| node.text.squish == "New Scan" }

          expect(creation_links.size).to eq(1)
          expect(response.body).not_to include("Create Scan")
        end
      end
    end
  end

  describe "GET #new" do
    it "returns success" do
      get :new
      expect(response).to have_http_status(:success)
    end

    it "loads probe categories filtered by policy_scope" do
      get :new
      # The controller uses policy_scope(Probe) for tier-based filtering
      expect(response).to have_http_status(:success)
    end

    context "default probe pre-selection" do
      let!(:results_scan) { ActsAsTenant.with_tenant(company) { create(:complete_scan, company: company) } }
      let!(:results_report) do
        ActsAsTenant.with_tenant(company) do
          create(:report, :completed, company: company, scan: results_scan, target: target)
        end
      end

      def seed_result(name, passed, total)
        p = create(:probe, name: name, detector: create(:detector))
        ActsAsTenant.with_tenant(company) { create(:probe_result, report: results_report, probe: p, passed: passed, total: total) }
        p
      end

      it "pre-checks successful probes above the attempts floor and shows the note" do
        winner = seed_result("attack.win", 9, 10)   # 90%, 10 attempts -> checked
        low_vol = seed_result("attack.lowvol", 3, 3) # 3 attempts -> below floor, not checked

        get :new

        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css("input#scan_probe_ids_#{winner.id}")["checked"]).to eq("checked")
        expect(doc.at_css("input#scan_probe_ids_#{low_vol.id}")["checked"]).to be_nil
        expect(response.body).to include("most successful against your past targets")
      end

      it "pre-checks nothing and renders no note when the tenant has no data" do
        fresh = create(:probe, name: "attack.fresh", detector: create(:detector))

        get :new

        doc = Nokogiri::HTML(response.body)
        expect(doc.at_css("input#scan_probe_ids_#{fresh.id}")["checked"]).to be_nil
        expect(response.body).not_to include("most successful against your past targets")
      end
    end
  end

  describe "POST #create" do
    let(:valid_params) do
      {
        scan: {
          name: "New Test Scan",
          target_ids: [ target.id ],
          probe_ids: [ probe.id ]
        }
      }
    end

    it "creates a scan with valid params" do
      expect {
        post :create, params: valid_params
      }.to change(Scan, :count).by(1)
    end

    it "redirects to scan show page on success" do
      post :create, params: valid_params
      expect(response).to redirect_to(scan_path(Scan.last))
    end

    it "keeps the submitted probe selection (not defaults) when create fails validation" do
      submitted = create(:probe, name: "attack.submitted", detector: create(:detector))
      default_only = create(:probe, name: "attack.defaultonly", detector: create(:detector)) # high ASR -> would be a default, but not submitted
      results_scan = ActsAsTenant.with_tenant(company) { create(:complete_scan, company: company) }
      results_report = ActsAsTenant.with_tenant(company) { create(:report, :completed, company: company, scan: results_scan, target: target) }
      ActsAsTenant.with_tenant(company) do
        create(:probe_result, report: results_report, probe: submitted, passed: 1, total: 10)
        create(:probe_result, report: results_report, probe: default_only, passed: 9, total: 10)
      end

      # Omitting target_ids fails Scan's targets-presence validation -> re-renders :new.
      post :create, params: { scan: { name: "Invalid Scan", probe_ids: [ submitted.id.to_s ] } }

      expect(response).to have_http_status(:unprocessable_entity)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("input#scan_probe_ids_#{submitted.id}")["checked"]).to eq("checked")
      expect(doc.at_css("input#scan_probe_ids_#{default_only.id}")["checked"]).to be_nil
    end
  end

  describe "POST #rerun" do
    it "relaunches the scan" do
      expect_any_instance_of(Scan).to receive(:rerun)
      post :rerun, params: { id: scan.id }
      expect(response).to redirect_to(reports_path)
    end

    it "displays success notice" do
      allow_any_instance_of(Scan).to receive(:rerun)
      post :rerun, params: { id: scan.id }
      expect(flash[:notice]).to include("launched successfully")
    end
  end

  describe "GET #stats" do
    it "returns JSON stats" do
      get :stats, params: { id: scan.id }, format: :json
      expect(response).to have_http_status(:success)
      expect(response.content_type).to include("application/json")
    end
  end

  describe "the token usage estimate" do
    it "labels input, output and total separately and states its basis" do
      probe = create(:probe, name: "encoding.InjectBase64", input_tokens: 0, prompts: [])
      ActsAsTenant.with_tenant(company) do
        past = create(:complete_scan, company: company)
        tgt = create(:target, company: company)
        report = create(:report, company: company, scan: past, target: tgt, status: :completed)
        create(:probe_result, report: report, probe: probe,
                              input_tokens: 15_140, output_tokens: 322_879, total: 40)
        scan.probes = [ probe ]
        scan.targets = [ tgt ]
      end

      get :show, params: { id: scan.id }

      expect(response.body).to include("Projected Input")
      expect(response.body).to include("Projected Output")
      expect(response.body).to include("Projected Total")
      expect(response.body).to match(/measured from previous runs/i)
    end

    it "says a projection is unavailable instead of showing a confident small number" do
      probe = create(:probe, name: "encoding.InjectHex", input_tokens: 0, prompts: [])
      ActsAsTenant.with_tenant(company) do
        scan.probes = [ probe ]
        scan.targets = [ create(:target, company: company) ]
      end

      get :show, params: { id: scan.id }

      expect(response.body).to match(/unavailable/i)
    end

    it "does not claim an estimate exists when there is no basis at all" do
      # The basis line branched on measured?, so "not measured" printed "estimated from
      # probe prompts" -- directly under a row saying unavailable with 0 of 1 probes
      # covered. Absence of a basis is a third state, and it has to say so.
      probe = create(:probe, name: "encoding.InjectHex", input_tokens: 0, prompts: [])
      ActsAsTenant.with_tenant(company) do
        scan.probes = [ probe ]
        scan.targets = [ create(:target, company: company) ]
      end

      get :show, params: { id: scan.id }

      expect(response.body).not_to match(/estimated from probe prompts/i)
      expect(response.body).to match(/no measured history or stored prompts/i)
    end

    it "never renders a non-trivial scan as zero minutes" do
      # The reported defect: 89.3 minutes of real runtime displayed as "0m".
      probe = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
      ActsAsTenant.with_tenant(company) do
        tgt = create(:target, company: company)
        past = create(:complete_scan, company: company)
        report = create(:report, company: company, scan: past, target: tgt, status: :completed)
        create(:probe_result, report: report, probe: probe,
                              input_tokens: 1_000, output_tokens: 1_000, total: 10)
        scan.probes = [ probe ]
        scan.targets = [ tgt ]
        own_run = create(:report, company: company, scan: scan, target: tgt, status: :completed,
                                  start_time: 89.minutes.ago, end_time: Time.current)
        # The own-run rung only reuses a duration measured on the scan's current probe set,
        # so the run has to record which probes it ran.
        create(:probe_result, report: own_run, probe: probe,
                              input_tokens: 1_000, output_tokens: 1_000, total: 10)
      end

      get :show, params: { id: scan.id }

      expect(response.body).not_to match(/~\s*0m/)
    end

    it "qualifies a row that covers fewer probes than the shared basis line claims" do
      # Output cannot be estimated from prompt text, so a measured probe alongside a
      # prompts-only probe leaves input covering 2 of 2 and output covering 1 of 2. The
      # page printed a single Basis line taken from input, presenting the output number as
      # a whole-scan figure.
      measured = create(:probe, name: "Measured", input_tokens: 0, prompts: [])
      prompts_only = create(:probe, name: "PromptsOnly", input_tokens: 244, prompts: [ "hi" ])
      ActsAsTenant.with_tenant(company) do
        tgt = create(:target, company: company)
        past = create(:complete_scan, company: company)
        report = create(:report, company: company, scan: past, target: tgt, status: :completed)
        create(:probe_result, report: report, probe: measured,
                              input_tokens: 1_000, output_tokens: 8_500, total: 10)
        scan.probes = [ measured, prompts_only ]
        scan.targets = [ tgt ]
      end

      get :show, params: { id: scan.id }

      expect(response.body).to include("2 of 2 probes covered") # the Basis line, from input
      expect(response.body).to include("1 of 2 probes covered") # the output row's own coverage
    end
  end

  describe "DELETE #destroy" do
    it "deletes the scan" do
      expect {
        delete :destroy, params: { id: scan.id }
      }.to change(Scan, :count).by(-1)
    end

    it "redirects to scans index" do
      delete :destroy, params: { id: scan.id }
      expect(response).to redirect_to(scans_path)
    end
  end

  describe "POST #batch" do
    let!(:scan2) do
      ActsAsTenant.with_tenant(company) do
        create(:complete_scan, company: company)
      end
    end

    describe "batch_rerun" do
      it "reruns selected scans" do
        allow_any_instance_of(Scan).to receive(:rerun)
        post :batch, params: { batch_action: "rerun", ids: [ scan.id, scan2.id ] }
        expect(flash[:notice]).to include("launched successfully")
      end
    end

    describe "batch_destroy" do
      it "destroys selected scans" do
        expect {
          post :batch, params: { batch_action: "destroy", ids: [ scan.id, scan2.id ] }
        }.to change(Scan, :count).by(-2)
      end
    end
  end

  describe "batch actions are tenant-scoped (cross-tenant guard)" do
    let!(:other_company) { create(:company, tier: :tier_4) }
    let!(:other_scan) { ActsAsTenant.with_tenant(other_company) { create(:complete_scan, company: other_company) } }

    it "POST #batch_destroy does not delete another tenant's scan" do
      post :batch_destroy, params: { ids: [ other_scan.id ] }

      survives = ActsAsTenant.without_tenant { Scan.where(id: other_scan.id).exists? }
      expect(survives).to be(true)
    end

    it "POST #batch_rerun does not rerun another tenant's scan" do
      expect_any_instance_of(Scan).not_to receive(:rerun)

      post :batch_rerun, params: { ids: [ other_scan.id ] }
    end
  end
end
