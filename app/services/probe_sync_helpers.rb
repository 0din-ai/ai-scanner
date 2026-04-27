module ProbeSyncHelpers
  private

  def update_probe_attributes(probe, probe_json, source:, attribution: nil, scores: nil, prompts: nil, input_tokens: 0, warn_missing_taxonomy: false)
    taxonomy_categories = probe_json["techniques"]&.map { |t| taxonomy_categories_map[t] }

    if warn_missing_taxonomy && (taxonomy_categories.nil? || taxonomy_categories.empty?)
      Rails.logger.error "No taxonomy category found for probe: #{probe.name}"
    end

    attrs = {
      guid: probe_json["guid"],
      summary: probe_json["summary"],
      release_date: probe_json["release_date"],
      modified_date: probe_json["modified_date"],
      description: probe_json["description"],
      techniques: probe_json["techniques"]&.map { |t| Technique.find_or_create_by!(name: t) }.to_a,
      detector_id: probe_json["detector"].present? ? Detector.find_or_create_by!(name: probe_json["detector"]).id : nil,
      scores: scores,
      prompts: prompts,
      input_tokens: input_tokens,
      enabled: probe_active?(probe_json),
      source: source,
      attribution: attribution,
      taxonomy_categories: taxonomy_categories&.compact&.uniq.to_a,
      published: probe_json["published"] || false,
      published_at: parse_published_at(probe_json["published_at"])
    }

    # Enum fields - only set when value present (requires engine to define the enum mappings)
    attrs[:disclosure_status] = probe_json["disclosure_status"] if probe_json["disclosure_status"].present?
    attrs[:social_impact_score] = probe_json["social_impact_score"] if probe_json["social_impact_score"].present?

    probe.update!(attrs)
  end

  def disable_outdated_probes(source:, valid_names:, enabled_names: valid_names)
    disabled_count = 0
    enabled_count = 0

    outdated_probes = Probe.where(source: source).where.not(name: valid_names)
    outdated_probes.find_each do |probe|
      if probe.enabled?
        probe.update!(enabled: false)
        disabled_count += 1
        Rails.logger.info "Disabled outdated #{source} probe: #{probe.name} (#{probe.guid})"
      end
    end

    Rails.logger.info "Disabled #{disabled_count} outdated #{source} probes"

    previously_disabled = Probe.where(source: source, name: enabled_names, enabled: false)
    if previously_disabled.any?
      enabled_count = previously_disabled.count
      previously_disabled.update_all(enabled: true)
      Rails.logger.info "Re-enabled #{enabled_count} #{source} probes"
    end

    { disabled_count: disabled_count, enabled_count: enabled_count }
  end

  def taxonomy_categories_map
    @taxonomy_categories_map ||= JSON.parse(File.read(Rails.root.join("config", "taxonomies.json")))
                                     .each_with_object({}) do |category, map|
      category_name = category["name"]
      category["children"].each do |strategy|
        strategy["children"].each do |technique|
          map[technique["name"]] = find_or_create_taxonomy_category(category_name)
        end
      end
    end
  end

  def find_or_create_taxonomy_category(name)
    TaxonomyCategory.where("LOWER(name) = LOWER(?)", name).first_or_create!(name: name)
  end

  def parse_published_at(value)
    return nil if value.blank?
    Time.zone.parse(value)
  rescue ArgumentError => e
    Rails.logger.warn "SyncProbesJob: Invalid published_at value '#{value}': #{e.message}"
    nil
  end

  def sanitize_log_message(message)
    message.to_s.gsub(/[\r\n\t]/, " ")
  end

  def probe_active?(probe_json)
    probe_json["active"] != false
  end

  def inactive_enabled_probes_need_sync?(source:, data:)
    return false unless data.is_a?(Hash) && data["probes"].is_a?(Hash)

    inactive_names = data["probes"].filter_map do |name, probe_json|
      name unless probe_active?(probe_json)
    end
    return false if inactive_names.empty?

    Probe.where(source: source, name: inactive_names, enabled: true).exists?
  end
end
