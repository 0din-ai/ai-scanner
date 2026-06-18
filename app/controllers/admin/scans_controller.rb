# frozen_string_literal: true

module Admin
  class ScansController < Admin::BaseController
    include ScanHelper

    before_action :set_scan, only: [ :show, :edit, :update, :destroy, :rerun, :stats ]

    def index
      authorize Scan
      @page_title = "Scans"
      @quota_exhausted = !current_company.scan_allowed?

      # Calculate scope counts for tabs
      @scheduled_count = Scan.scheduled.count
      @unscheduled_count = Scan.unscheduled.count
      @all_count = Scan.count

      # Handle scopes
      base_scope = case params[:scope]
      when "unscheduled"
        Scan.unscheduled
      when "all"
        Scan.all
      else # scheduled is default
        Scan.scheduled
      end

      # reports_count is now a real column (counter cache), no special handling needed
      base_scope = base_scope.includes(:probes, :targets)

      @q = base_scope.ransack(params[:q])
      sort_param = params.dig(:q, :s).to_s

      # Apply default order only when no sort is specified
      if sort_param.blank?
        @pagy, @scans = pagy(@q.result.order(created_at: :desc))
      else
        @pagy, @scans = pagy(@q.result)
      end
      @current_scope = params[:scope] || "scheduled"

      # Load filter options
      @filter_targets = Target.order(:name).pluck(:name, :id)
    end

    def show
      authorize @scan
      @page_title = "Scan: #{@scan.name}"
      @quota_exhausted = !current_company.scan_allowed?
    end

    def new
      @scan = Scan.new
      authorize @scan
      @page_title = "New Scan"
      load_form_data
      @default_probe_ids = Scans::DefaultProbeSelector.new(probe_scope: policy_scope(Probe).enabled).call
    end

    def create
      @scan = Scan.new(scan_params)
      authorize @scan

      if !@scan.scheduled? && !current_company.scan_allowed?
        redirect_to scans_path, alert: quota_exhausted_message
        return
      end

      if @scan.save
        redirect_to scan_path(@scan), notice: "Scan was successfully created."
      else
        @page_title = "New Scan"
        load_form_data
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize @scan
      @page_title = "Edit #{@scan.name}"
      load_form_data
    end

    def update
      authorize @scan
      if @scan.update(scan_params)
        redirect_to scan_path(@scan), notice: "Scan was successfully updated."
      else
        @page_title = "Edit #{@scan.name}"
        load_form_data
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      authorize @scan
      @scan.destroy
      redirect_to scans_path, notice: "Scan was successfully deleted.", status: :see_other
    end

    # Rerun a scan with same configuration
    def rerun
      authorize @scan
      unless current_company.scan_allowed?
        redirect_to scan_path(@scan), alert: quota_exhausted_message
        return
      end
      @scan.rerun
      redirect_to reports_path, notice: "Scan launched successfully."
    end

    # Stats modal data (AJAX)
    def stats
      authorize @scan
      render json: Scans::StatsSerializer.new(@scan).call
    end

    # Unified batch action dispatcher (for shared table component)
    def batch
      authorize Scan, :index?
      case params[:batch_action]
      when "rerun"
        batch_rerun
      when "destroy"
        batch_destroy
      else
        redirect_to scans_path(scope: params[:scope]), alert: "Unknown batch action"
      end
    end

    # Batch actions
    def batch_rerun
      ids = params[:ids] || []
      unless current_company.scan_allowed?
        redirect_to scans_path(scope: params[:scope]), alert: quota_exhausted_message
        return
      end
      count = 0
      Scan.where(id: ids).find_each do |scan|
        scan.rerun
        count += 1
      end
      redirect_to scans_path(scope: params[:scope]), notice: "#{count} scan(s) have been launched successfully."
    end

    def batch_destroy
      ids = params[:ids] || []
      destroyed = Scan.where(id: ids).destroy_all.count
      redirect_to scans_path(scope: params[:scope]), notice: "#{destroyed} scan(s) have been deleted.", status: :see_other
    end

    private

    def set_scan
      @scan = Scan.find(params[:id])
    end

    def quota_exhausted_message
      "Weekly scan quota reached (#{current_company.weekly_scan_count}/#{current_company.scans_per_week_limit}). Resets next Monday."
    end

    def scan_params
      permitted = [
        :name, :recurrence, :output_server_id,
        :auto_update_generic, :auto_update_cm, :auto_update_hp,
        { target_ids: [], probe_ids: [] }
      ]
      permitted << { threat_variant_subindustry_ids: [] } if current_company.can_use?(:industry_variants) && Scan.reflect_on_association(:threat_variant_subindustries)
      permitted << :priority if current_user.super_admin?
      params.require(:scan).permit(permitted)
    end

    def load_form_data
      # Include tokens_per_second for JS estimation; tok/s shown via Choices.js labelDescription
      @targets = Target.pluck(:id, :name, :tokens_per_second, :target_type).map do |id, name, tps, type|
        data = { "data-tokens-per-second" => tps, "data-target-type" => type }
        data["data-label-description"] = " (#{tps.round(1)} tok/s)" if type == "api" && tps
        [ name, id, data ]
      end
      @output_servers = OutputServer.all.map { |os| [ os.name, os.id ] }

      # Separate curated and community (garak) probes
      # NOTE: policy_scope applies tier-based filtering via ProbeAccess
      @probe_categories = {}
      @community_categories = {}

      # Group probes by detector AND source to avoid name collisions
      # (e.g., curated.MitigationBypass vs mitigation.MitigationBypass)
      policy_scope(Probe).enabled.includes(:detector).group_by { |p| [ p.detector, p.source ] }.each do |(detector, source), probes|
        next unless detector

        short_name = detector.name.split(".").last
        is_community = source == "garak"

        # For community probes, use detector short name directly
        # For curated probes, use translated name
        if is_community
          category_name = short_name
        else
          category_name = I18n.t("detectors.names.#{short_name}", default: short_name)
        end

        category_data = {
          probes: probes,
          icon: detector_icon(short_name),
          color: detector_color(short_name)
        }

        if is_community
          @community_categories[category_name] = category_data
        else
          @probe_categories[category_name] = category_data
        end
      end

      @probe_categories = @probe_categories.sort.to_h
      @community_categories = @community_categories.sort.to_h

      # Load threat variant industries with subindustries (engine-only model)
      @threat_variant_industries = if defined?(ThreatVariantIndustry)
        ThreatVariantIndustry.includes(threat_variant_subindustries: { threat_variants: :probe }).all
      else
        []
      end
    end
  end
end
