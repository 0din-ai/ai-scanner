module VariantDefaults
  extend ActiveSupport::Concern

  included do
    has_and_belongs_to_many :variant_probes, join_table: :report_variant_probes, class_name: "Probe"

    validates :parent_report_id, uniqueness: { allow_nil: true, message: "can only have one child report" }
  end

  def is_variant_report?
    parent_report_id.present?
  end

  def has_variant_data?
    !is_variant_report? && child_report.present?
  end

  def should_show_variants_section?
    !is_variant_report? && scan&.has_threat_variants?
  end

  def variant_report_ready?
    has_variant_data? && child_report.completed?
  end

  def variant_count
    return 0 unless is_variant_report? && variant_probes.any?

    persisted = variants_by_industry
    if persisted.any?
      persisted.values.sum(&:count)
    else
      subindustry_ids = scan.threat_variant_subindustry_ids
      probe_names = variant_probes.map { |p| "#{p.category || '0din'}.#{p.name}" }
      VariantProbeMapper.new(probe_names, subindustry_ids).call.count
    end
  end

  def variants_by_industry
    return {} unless is_variant_report?

    @variants_by_industry ||= begin
      variant_ids = probe_results.where.not(threat_variant_id: nil).pluck(:threat_variant_id)
      return {} if variant_ids.empty?

      ThreatVariant
        .where(id: variant_ids)
        .includes(threat_variant_subindustry: :threat_variant_industry)
        .to_a
        .uniq(&:prompt)
        .group_by { |v| v.threat_variant_subindustry.threat_variant_industry }
    end
  end

  def variant_probe_results
    @variant_probe_results ||= probe_results
      .includes(:probe, :detector, threat_variant: { threat_variant_subindustry: :threat_variant_industry })
      .order(:id)
      .to_a
  end

  def all_selected_variant_industries_grouped
    return {} unless scan&.has_threat_variants?

    @all_selected_variant_industries_grouped ||= begin
      sub_ids = all_subindustry_ids
      ThreatVariantIndustry
        .joins(:threat_variant_subindustries)
        .where(threat_variant_subindustries: { id: sub_ids })
        .includes(:threat_variant_subindustries)
        .distinct
        .order(:name)
        .each_with_object({}) do |industry, hash|
          hash[industry] = industry.threat_variant_subindustries
            .select { |s| sub_ids.include?(s.id) }
            .sort_by(&:name)
        end
    end
  end

  def all_subindustry_ids
    @all_subindustry_ids ||= scan.threat_variant_subindustry_ids
  end

  def preloaded_variant_data
    @preloaded_variant_data ||= begin
      if has_variant_data?
        parent_prs = probe_results.to_a
        child_prs = child_report.probe_results
          .includes(:probe, threat_variant: { threat_variant_subindustry: :threat_variant_industry })
          .order(:id)
          .to_a

        grouped = child_prs.group_by(&:probe_id)
        sub_ids = all_subindustry_ids

        attack_counts = {}
        success_rates = {}
        subindustry_maps = {}
        all_attempts = {}

        parent_prs.each do |pr|
          pid = pr.probe_id
          children = grouped[pid] || []

          total = children.sum(&:total)
          passed = children.sum(&:passed)
          attack_counts[pid] = { total: total, passed: passed }
          success_rates[pid] = total.zero? ? 0 : (passed.to_f / total * 100).round(1)

          map = sub_ids.each_with_object({}) { |id, h| h[id] = nil }
          children.each do |cpr|
            sub_id = cpr.threat_variant&.threat_variant_subindustry_id
            map[sub_id] = cpr if sub_id
          end
          subindustry_maps[pid] = map

          attempts_arr = []
          (pr.attempts || []).each do |a|
            attempts_arr << { attempt: a, is_variant: false, variant_industry: nil }
          end
          children.each do |vpr|
            next unless vpr.attempts
            label = build_variant_label(vpr)
            vpr.attempts.each do |a|
              attempts_arr << { attempt: a, is_variant: true, variant_industry: label }
            end
          end
          all_attempts[pid] = attempts_arr
        end

        { attack_counts: attack_counts, success_rates: success_rates,
          subindustry_maps: subindustry_maps, all_attempts: all_attempts }
      else
        { attack_counts: {}, success_rates: {}, subindustry_maps: {}, all_attempts: {} }
      end
    end
  end

  def all_attempts_for_probe(probe_result)
    return [] unless probe_result

    if has_variant_data?
      preloaded_variant_data[:all_attempts][probe_result.probe_id] || []
    else
      (probe_result.attempts || []).map { |a| { attempt: a, is_variant: false, variant_industry: nil } }
    end
  end

  private

  def build_variant_label(variant_pr)
    subindustry = variant_pr.threat_variant&.threat_variant_subindustry
    industry = subindustry&.threat_variant_industry
    if industry && subindustry
      "#{industry.name} / #{subindustry.name}"
    else
      "Unknown Variant"
    end
  end

  def notify_status_change
    case status.to_sym
    when :running
      notify_variant_scan_started if is_variant_report?
    when :completed
      notify_scan_completed
    when :failed
      notify_scan_failed
    end
  end

  def notify_variant_scan_started
    count = variant_count
    return if count == 0

    industries = scan.threat_variant_subindustries
      .includes(:threat_variant_industry)
      .map { |sub| sub.threat_variant_industry.name }
      .uniq
      .sort

    industry_list = case industries.length
    when 0
      "industry-specific variants"
    when 1
      industries.first
    when 2
      industries.join(" and ")
    else
      "#{industries[0..-2].join(', ')}, and #{industries.last}"
    end

    variant_text = count == 1 ? "variant" : "variants"
    parent_name = parent_report&.name || "scan"

    ToastNotifier.call(
      type: "warning",
      title: "Variant Analysis Started",
      message: "Testing #{count} #{variant_text} for #{industry_list} based on successful attacks from #{parent_name}.",
      link: Rails.application.routes.url_helpers.report_path(self),
      link_text: "View Progress",
      company_id: company_id
    )
  end

  def notify_scan_completed
    message = if is_variant_report?
      "Variant analysis #{name} has completed successfully."
    else
      "Scan #{name} has completed successfully."
    end

    ToastNotifier.call(
      type: "success",
      title: is_variant_report? ? "Variant Analysis Completed" : "Scan Completed",
      message: message,
      link: Rails.application.routes.url_helpers.report_path(self),
      link_text: "View Report",
      company_id: company_id
    )
  end

  def notify_scan_failed
    message = if is_variant_report?
      "Variant analysis #{name} has failed."
    else
      "Scan #{name} has failed."
    end

    ToastNotifier.call(
      type: "error",
      title: is_variant_report? ? "Variant Analysis Failed" : "Scan Failed",
      message: message,
      link: Rails.application.routes.url_helpers.report_path(self),
      link_text: "View Report",
      company_id: company_id
    )
  end
end
