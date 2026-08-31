# frozen_string_literal: true

module Admin
  class ReportsController < Admin::BaseController
    # probes_tab and attempt_content load @report with custom includes — excluded intentionally
    before_action :set_report, only: [ :show, :destroy, :stop, :asr_history, :top_probes, :progress ]
    before_action :set_debug_lease_report, only: [ :refresh_debug_lease ]

    include TargetsHelper

    def index
      authorize Report
      @page_title = "Reports"
      @scope = params[:scope] || "all"

      # Build base scope based on selected tab
      base_scope = case @scope
      when "completed" then Report.completed
      when "failed" then Report.failed
      when "running" then Report.running
      when "pending" then Report.pending
      when "starting" then Report.starting
      when "interrupted" then Report.interrupted
      when "variants" then Report.child_reports_only.includes(:parent_report)
      else Report.parent_reports
      end

      # Apply optional scan filter if coming from scan page
      base_scope = base_scope.where(scan_id: params[:scan_id]) if params[:scan_id]

      # Apply ransack search with pre-calculated detector stats to avoid N+1 queries
      @q = base_scope.includes(:target, :scan).with_result_stats.ransack(params[:q])
      @pagy, @reports = pagy(apply_sorting(@q.result))

      # Calculate scope counts for tabs
      count_base = params[:scan_id] ? Scan.find(params[:scan_id]).reports : Report
      @scope_counts = {
        all: count_base.parent_reports.count,
        completed: count_base.parent_reports.completed.count,
        failed: count_base.parent_reports.failed.count,
        running: count_base.parent_reports.running.count,
        pending: count_base.parent_reports.pending.count,
        starting: count_base.parent_reports.starting.count,
        interrupted: count_base.parent_reports.interrupted.count,
        variants: Report.child_reports_only.count
      }

      # Load filter options
      @filter_targets = Target.order(:name).pluck(:name, :id)
    end

    def show
      authorize @report
      @page_title = "Report ##{@report.id}"
      # Activity Stream leases are refreshed by the mounted lease controller.
    end

    def destroy
      authorize @report
      @report.destroy
      redirect_to reports_path(preserve_params), notice: "Report was successfully deleted.", status: :see_other
    end

    # Member action: stop a single report
    def stop
      authorize @report
      Reports::Stop.new(@report).call
      redirect_back(fallback_location: report_path(@report), notice: "Report stopped successfully.")
    end

    # Unified batch action dispatcher (for shared table component)
    def batch
      authorize Report, :index?
      case params[:batch_action]
      when "stop"
        batch_stop
      when "destroy"
        batch_destroy
      else
        redirect_to reports_path(preserve_params), alert: "Unknown batch action"
      end
    end

    # Batch action: stop multiple reports
    # SECURITY: authorize explicitly (the standalone route bypasses #batch's guard, and
    # verify_authorized is an after_action so the work would otherwise run before authz)
    # and scope to the current tenant — acts_as_tenant returns ALL rows when the tenant
    # is nil (require_tenant=false), so an unscoped where(id:) could span tenants.
    def batch_stop
      authorize Report, :batch_stop?
      ids = params[:ids] || []
      tenant_scoped_reports(ids).find_each do |report|
        Reports::Stop.new(report).call
      end
      redirect_to reports_path(preserve_params), notice: "Selected reports have been stopped."
    end

    # Batch action: destroy multiple reports (see batch_stop for the SECURITY rationale).
    def batch_destroy
      authorize Report, :batch_destroy?
      ids = params[:ids] || []
      count = tenant_scoped_reports(ids).destroy_all.count
      redirect_to reports_path(preserve_params), notice: "#{count} reports were successfully deleted.", status: :see_other
    end

    # JSON endpoint for ASR history chart
    def asr_history
      authorize @report
      # Get ASR history for this scan - last 10 reports or current report if alone
      # with_result_stats provides cached_passed/cached_total to avoid N+1 on the ASR figure
      # Measurement-eligible runs only, the same rule the scan's aggregate figures and
      # the projections apply. A partial run measured less work than it planned, so
      # plotting its ASR alongside full runs shows a drop that is an artefact of how
      # much ran rather than of how the target behaved -- and the report page already
      # marks that run partial, so the chart would contradict it.
      # parent_reports: a variant child is a re-run of probes its parent already
      # measured, so plotting it puts the same work on the chart twice as if it were a
      # later, separate run.
      reports = Scans::HistoryEligibility.apply(Report.where(scan_id: @report.scan_id).parent_reports)
                      .with_result_stats
                      .order(created_at: :desc)
                      .limit(10)
                      .reverse

      # If no reports, return empty data
      if reports.empty?
        render json: { dates: [], asr_values: [], successful_attacks: [] }
        return
      end

      dates = []
      asr_values = []
      successful_attacks = []

      reports.each do |report|
        dates << report.created_at.strftime("%m/%d")
        # From the canonical figure, not attack_success_rate: that is already rounded to
        # 2dp, so rounding again moved the value (12/961 plotted 1.3 while the page said
        # 1.2). nil leaves a gap for a report with nothing to measure -- a plotted 0
        # would read as a perfect result where the page says N/A.
        asr_values << report.asr.percent&.round(1)
        successful_attacks << report.total_successful_attacks
      end

      render json: {
        dates: dates,
        asr_values: asr_values,
        successful_attacks: successful_attacks
      }
    end

    # Probes tab content loaded via Turbo Frame
    def probes_tab
      scan_includes = if Scan.reflect_on_association(:threat_variant_subindustries)
        { scan: :threat_variant_subindustries }
      else
        :scan
      end

      @report = Report.includes(:child_report, scan_includes).find(params[:id])
      authorize @report
      @probe_results = @report.probe_results.for_report_probe_cards.to_a
      render layout: false
    end

    # Live progress for a run that has not finished, polled from the report page.
    #
    # Conditional on the DERIVED representation rather than on updated_at. A run
    # crossing the stall threshold writes nothing to the database, so an updated_at
    # etag would serve the same card indefinitely while the answer changed underneath
    # it -- and a matching etag lets this skip the journal read entirely, which is the
    # expensive half.
    def progress
      authorize @report

      @progress = Reports::Progress.new(@report)

      return unless stale?(etag: @progress.representation_key, public: false)

      render partial: "admin/reports/progress_card_body",
             locals: { report: @report, progress: @progress },
             layout: false
    end

    # One flat, filterable list of every attempt in the report.
    #
    # Evidence was previously reachable only by expanding a probe card, then its
    # prompts frame, then an attempt -- and there was no way at all to ask "which
    # attacks got through?" across the whole report.
    def evidence
      @report = Report.includes(:child_report).find(params[:id])
      authorize @report

      # This action answers a lazy turbo frame inside the report page, so it renders
      # without a layout -- which means no importmap and no Stimulus. A deep link
      # pasted into the address bar therefore arrived as a bare, dead fragment: the
      # server had resolved the attempt and the page it sits on, and nothing on the
      # client was running to open the drawer onto it. Send a real navigation to the
      # report page instead and let it hand these coordinates to the frame.
      unless turbo_frame_request?
        redirect_to report_path(@report, params.permit(:probe_result_id, :attempt_index, :filter, :q, :page)
                                               .to_h.compact_blank.merge(tab: "evidence"))
        return
      end

      # An unrecognised filter falls through to no outcome condition, so a junk
      # value shows everything with All active rather than an empty table.
      @filter = Reports::EvidenceRows::FILTERS.key?(params[:filter].to_s) ? params[:filter].to_s : nil
      @query = params[:q].presence
      @page = [ params[:page].to_i, 1 ].max

      rows = Reports::EvidenceRows.new(@report, filter: @filter, query: @query)
      @per_page = Reports::EvidenceRows::DEFAULT_PER_PAGE
      @counts = rows.counts
      @total = rows.total
      @last_page = [ (@total.to_f / @per_page).ceil, 1 ].max

      # Both coordinates must be plain integers before they are used. page_for casts
      # with to_i, so "0junk" would place itself at index 0 and reach the drawer
      # verbatim, which then asks evidence_attempt for "0junk" and gets a 400 -- a
      # drawer opened onto an error.
      @selected_probe_result_id = params[:probe_result_id].to_s[/\A\d+\z/]
      @selected_attempt_index = params[:attempt_index].to_s[/\A\d+\z/]

      if @selected_probe_result_id && @selected_attempt_index
        selected_page = rows.page_for(probe_result_id: @selected_probe_result_id,
                                      attempt_index: @selected_attempt_index,
                                      per_page: @per_page)
        if selected_page.nil?
          # The link names no row in this filtered set -- stale, or written before a
          # filter was applied. The tab still renders; it just does not open a drawer
          # onto nothing.
          @selected_probe_result_id = nil
          @selected_attempt_index = nil
        elsif params[:page].blank?
          # An explicit page always wins, so paging away from a deep-linked row is not
          # undone on the next request.
          @page = selected_page
        end
      end

      # Clamped AFTER the deep link is resolved, so ?page=9999 lands on the last real
      # page instead of rendering an empty table with no way back.
      @page = @page.clamp(1, @last_page)
      @rows = rows.rows(limit: @per_page, offset: (@page - 1) * @per_page)

      render layout: false
    end

    # The full evidence for one attempt: prompt, every response, verdict, score and
    # the detector scores behind it, in a single request.
    # The drawer fetches this with plain fetch(), which sends no Turbo-Frame header.
    # That is fine here and must stay fine: do not add the non-frame redirect guard
    # that evidence has, or every drawer request would bounce to the report page.
    def evidence_attempt
      @report = Report.includes(:child_report).find(params[:id])
      authorize @report

      raw_index = params[:attempt_index]
      unless raw_index&.match?(/\A\d+\z/)
        head :bad_request
        return
      end

      probe_result = evidence_probe_result
      # The RAW stored array, indexed as EvidenceRows addresses it: the list keys each
      # row on its original ordinality, so gaps left by malformed rows are preserved
      # and this index still points at the row the reader clicked.
      attempt = probe_result && Array(probe_result.attempts)[raw_index.to_i]

      if attempt.nil?
        head :not_found
        return
      end

      @attempt = attempt
      # The same extraction the evidence search mirrors, so a phrase that matched in
      # the list is the phrase shown here.
      @prompt = TokenEstimator.extract_prompt_text(attempt["prompt"]) || ""
      # EVERY generation, not just the first. attack_succeeded and detector_scores are
      # maxima across garak's per-generation scores, so showing only the first put a
      # refusal under a "succeeded" badge while the generation that actually succeeded
      # was not on the page.
      @responses = attempt_outputs(attempt["outputs"])
                     .map { |output| TokenEstimator.extract_output_text(output).to_s }
      @detector_scores = attempt["detector_scores"]
      # The badge claims the attempt is a threat variant of the probe, which is what
      # threat_variant_id records. Deriving it from "came from the child report"
      # instead got it wrong from both directions: opened on a variant report every
      # row lost its badge, and a child row that resolved no variant still carried
      # one when read from the parent.
      @variant = probe_result.threat_variant_id.present?
      @probe_name = probe_result.probe&.name

      # The list is paged, so the rows either side of this one may not be rendered.
      # The filter and search come along because the reader is stepping through the
      # list they are looking at, not the whole report.
      @neighbours = Reports::EvidenceRows
                    .new(@report, filter: params[:filter].presence, query: params[:q].presence)
                    .neighbours(probe_result_id: probe_result.id, attempt_index: raw_index.to_i)

      render layout: false
    end

    # Probe attempt rows loaded on demand from each probe card.
    def probe_attempts
      @report = Report.includes(:child_report).find(params[:id])
      authorize @report

      @probe_result = @report.probe_results.find(params[:probe_result_id])

      raw_probe_index = params[:probe_index].to_s
      if params.key?(:probe_index) && !raw_probe_index.match?(/\A\d+\z/)
        head :bad_request
        return
      end
      @probe_index = raw_probe_index.match?(/\A\d+\z/) ? raw_probe_index.to_i : 0

      @attempt_items = @report.all_attempts_for_probe(@probe_result)

      render layout: false
    end

    # Attempt prompt/response content loaded via Turbo Frame on card expand
    def attempt_content
      @report = Report.includes(:child_report).find(params[:id])
      authorize @report

      probe_result = @report.probe_results.find(params[:probe_result_id])
      raw_index = params[:attempt_index]
      unless raw_index&.match?(/\A\d+\z/)
        head :bad_request
        return
      end
      attempt_index = raw_index.to_i

      # The same list probe_attempts renders, unconditionally. This endpoint resolves
      # an item BY INDEX, so any list that differs from the rendered one -- in
      # de-duplication or in order -- serves the wrong prompt and response for the row
      # the reader clicked. all_attempts_for_probe already returns main attempts alone
      # when there is no variant data, so there is nothing for a branch to save.
      item = @report.all_attempts_for_probe(probe_result)[attempt_index]

      if item.nil?
        Rails.logger.warn(
          "[attempt_content] No attempt found for report=#{@report.id} " \
          "probe_result=#{probe_result.id} index=#{attempt_index} " \
          "has_variant_data=#{@report.has_variant_data?}"
        )
        head :not_found
        return
      end

      attempt = item[:attempt]
      raw_prompt = attempt["prompt"] || attempt[:prompt]
      @prompt = TokenEstimator.extract_prompt_text(raw_prompt) || ""
      raw_response = (attempt["outputs"] || attempt[:outputs])&.first
      @response = TokenEstimator.extract_output_text(raw_response) || ""
      @attempt_frame_id = "attempt-content-#{probe_result.id}-#{attempt_index}"

      render layout: false
    end

    # Downloads the whole report -- prompts, responses and per-attempt verdicts --
    # as JSON.
    #
    # Spooled to a tempfile before any header goes out, rather than streamed
    # straight to the response. Streaming would commit a 200 with the first chunk,
    # before a single probe_result had been read, so anything failing part-way
    # through would hand the reader a truncated file that still looked like a
    # successful download. Buffering costs the wait but makes a failure a 500.
    #
    # Scoped explicitly by company as well as through policy_scope: tenancy is not
    # required app-wide, so a nil ambient tenant makes the policy scope span every
    # company. This action names the constraint rather than inheriting it.
    def json_export
      company = current_company
      raise ActiveRecord::RecordNotFound if company.nil?

      @report = policy_scope(Report).where(company_id: company.id).find(params[:id])
      authorize @report, :json_export?

      spool = Tempfile.new([ "report_export", ".json" ], binmode: true)
      Reports::JsonExportPayload.new(@report).each { |chunk| spool.write(chunk) }
      spool.flush
      spool.rewind

      filename = "report_#{@report.uuid}_#{@report.created_at.strftime('%Y-%m-%d')}.json"
      # The export carries prompts and model responses, so it must not be held by
      # a shared cache on the way to the reader.
      response.headers["Cache-Control"] = "no-store"
      send_file_headers! type: "application/json", disposition: "attachment", filename: filename
      response.headers["Content-Length"] = spool.size.to_s
      self.response_body = SpooledFileBody.new(spool)
    end

    # Streams the spooled file and removes it once the server is done with it,
    # whether the download completed or the connection dropped. Rack calls close
    # on the body in both cases; without it a failed download would leave the
    # tempfile behind until the process exited.
    class SpooledFileBody
      CHUNK = 64 * 1024

      def initialize(file)
        @file = file
      end

      def each
        while (chunk = @file.read(CHUNK))
          yield chunk
        end
      end

      def close
        @file.close
        @file.unlink
      rescue IOError, Errno::ENOENT
        nil
      end
    end

    def top_probes
      authorize @report
      # Get top 5 most vulnerable probes for this report
      probe_data = @report.probe_results
                          .includes(:probe)
                          .where("total > 0")
                          .map do |pr|
                            asr = (pr.passed.to_f / pr.total * 100).round(1)
                            {
                              name: pr.probe&.name || "Unknown",
                              asr: asr
                            }
                          end
                          .sort_by { |p| -p[:asr] }
                          .take(5)

      render json: {
        probe_names: probe_data.map { |p| p[:name] },
        asr_values: probe_data.map { |p| p[:asr] }
      }
    end

    def refresh_debug_lease
      authorize @report, :show?
      Reports::DebugWatcher.refresh_and_enqueue(@report)
      head :ok
    end

    private

    # probe_result_id is user input, so it is resolved only among THIS report's own
    # probe results and those of its variant child. Finding it by bare id would read
    # any tenant's prompts and responses.
    # garak writes outputs as a list, but a malformed row can hold a bare value.
    # Kernel#Array is the wrong wrapper for it: a hash becomes its key/value pairs,
    # so a { "text" => ... } output rendered as an empty response panel while the
    # evidence search -- which reads the same field in SQL -- still matched its
    # text. A reader following a search hit has to find it on the page.
    def attempt_outputs(outputs)
      case outputs
      when nil then []
      when Array then outputs
      else [ outputs ]
      end
    end

    def evidence_probe_result
      ids = [ @report.id ]
      ids << @report.child_report.id if @report.has_variant_data? && @report.child_report.present?

      ProbeResult.find_by(id: params[:probe_result_id], report_id: ids)
    end


    # Fail-closed tenant scoping for batch operations: explicitly filter by the current
    # company so a nil acts_as_tenant context can't span tenants.
    def tenant_scoped_reports(ids)
      tenant = ActsAsTenant.current_tenant
      return Report.none unless tenant

      Report.where(company_id: tenant.id, id: ids)
    end

    def set_report
      @report = Report.includes(:target, :scan,
                                detector_results: :detector)
                      .find(params[:id])
    end

    def set_debug_lease_report
      @report = Report.select(:id, :status, :company_id).find(params[:id])
    end

    def apply_sorting(scope)
      # Handle custom ASR sorting
      if params[:order]&.include?("asr")
        direction = params[:order].include?("desc") ? "DESC" : "ASC"

        # Ordered by the same totals the ASR column displays. Sorting on detector rows
        # while displaying probe rows left the table visibly out of order: a report can
        # show 80% and sort as 70%.
        scope.joins(Arel.sql(<<~SQL.squish))
          LEFT JOIN (
            SELECT report_id,
              SUM(passed) as passed_count,
              SUM(total) as total_count
            FROM probe_results
            GROUP BY report_id
          ) result_totals ON reports.id = result_totals.report_id
        SQL
        .order(Arel.sql(<<~SQL.squish))
          CASE
            WHEN COALESCE(result_totals.total_count, 0) = 0 THEN 0
            ELSE (CAST(COALESCE(result_totals.passed_count, 0) AS FLOAT) / result_totals.total_count * 100)
          END #{direction}
        SQL
      elsif params.dig(:q, :s)
        # Handle ransack sorting
        scope
      else
        # Default sorting
        scope.order(created_at: :desc)
      end
    end

    # Preserve URL parameters when redirecting
    def preserve_params
      request.query_parameters.except("batch_action", "collection_selection", "ids", "authenticity_token")
    end

    def set_page_title
      @page_title = "Reports"
    end
  end
end
