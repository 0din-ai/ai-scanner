# frozen_string_literal: true

module Admin
  class ProbesController < Admin::BaseController
    helper ProbeHelper

    def index
      authorize Probe
      @page_title = "Probes"

      # OPTIMIZED: Use cached columns instead of LEFT JOIN + GROUP BY
      # Success rate computed from pre-aggregated cached_passed_count and cached_total_count
      # This reduces query from scanning 181K+ probe_results rows to just reading probe columns
      # NOTE: policy_scope applies tier-based filtering via ProbeAccess
      base_scope = policy_scope(Probe)
        .includes(:techniques, :detector, :taxonomy_categories)
        .select(
          "probes.*",
          "cached_passed_count as success_count",
          "cached_total_count as total_count",
          "CASE
            WHEN cached_total_count > 0
            THEN (CAST(cached_passed_count AS FLOAT) / cached_total_count * 100)
            ELSE NULL
          END as success_rate_calculated"
        )

      @q = base_scope.ransack(params[:q])
      @q.sorts = "name asc" if @q.sorts.empty?  # Default sort by name
      @pagy, @probes = pagy(apply_sorting(@q.result))

      # Load filter options
      # A select has nowhere to put the identifier as secondary text, so the qualifier is
      # appended only where two detectors would otherwise offer the same option twice.
      detectors = Detector.all.to_a
      label_counts = detectors.group_by { |d| Detector.display_label(d.name) }.transform_values(&:size)
      @filter_detectors = detectors.map do |d|
        label = Detector.display_label(d.name)
        qualifier = Detector.qualifier_for(d.name)
        label = "#{label} (#{qualifier})" if qualifier && label_counts[label].to_i > 1
        [ label, d.id ]
      end
      @filter_disclosure_statuses = Probe.disclosure_statuses.map { |name, id| [ name.humanize, id ] }
      @filter_techniques = Technique.order(:name).pluck(:name, :id)
    end

    def show
      @probe = Probe.find(params[:id])
      authorize @probe
      @page_title = "Probe #{@probe.name}"

      # Use cached columns for stats display
      @success_count = @probe.cached_passed_count
      @total_count = @probe.cached_total_count
      @success_rate = @total_count > 0 ? (@success_count.to_f / @total_count * 100).round(1) : nil

      # Get successful targets for last 90 days
      @successful_targets_info = @probe.successful_targets_last_90_days
    end

    private

    def apply_sorting(scope)
      sort_param = params.dig(:q, :s)
      if sort_param&.start_with?("success_rate_calculated")
        # Custom sorting for success rate - ensure NULL values appear last
        direction = sort_param.include?("desc") ? "DESC" : "ASC"
        scope.reorder(Arel.sql("success_rate_calculated #{direction} NULLS LAST"))
      else
        scope
      end
    end
  end
end
