# frozen_string_literal: true

# Syncs 0DIN curated probes from a JSON file.
#
# In open-source mode, reads from config/probes/0din_probes.json (32 probes).
# The engine can override `file_path` via prepend to load the full probe set.
class OdinProbeSource
  include ProbeSyncHelpers

  SYNC_KEY = "0din_probes"
  FILE_PATH = "config/probes/0din_probes.json"
  CATEGORY = "0din"
  SOURCE = "0din"
  ATTRIBUTION = "0DIN by Mozilla - https://0din.ai"

  def needs_sync?
    unless File.exist?(Rails.root.join(file_path))
      Rails.logger.info "[OdinProbeSource] Probes file not found at #{file_path}, skipping sync"
      return false
    end

    DataSyncVersion.needs_sync?(SYNC_KEY, file_path) ||
      inactive_enabled_probes_need_sync?(source: SOURCE, data: load_probes_json)
  end

  def sync(sync_start_time)
    Rails.logger.info "Syncing 0DIN probes from #{file_path}..."
    @valid_probe_names = []
    @enabled_probe_names = []

    data = load_probes_json
    if !data.is_a?(Hash) || !data["probes"].is_a?(Hash)
      Rails.logger.error "Failed to load 0DIN probes JSON, skipping sync"
      return { success: false }
    end

    data["probes"].each { |name, probe_json| process_probe(name, probe_json) }
    variant_stats = sync_variants(data)

    disable_result = disable_outdated_probes(
      source: SOURCE,
      valid_names: @valid_probe_names,
      enabled_names: @enabled_probe_names
    )
    record_sync_version(sync_start_time, disable_result, variant_stats)
    { success: true }
  end

  private

  # Instance method so engine concern can override the file path
  def file_path
    FILE_PATH
  end

  # Base probes expand {substance} across these 4 default substances at runtime:
  # ["sarin gas", "mdma", "ricin", "mustard gas"]
  BASE_SUBSTANCE_COUNT = 4

  def process_probe(name, probe_json)
    @valid_probe_names << name
    @enabled_probe_names << name if probe_active?(probe_json)
    probe = Probe.find_or_create_by!(name: name, category: CATEGORY)

    prompts = probe_json["prompts"] || []
    input_tokens = estimate_probe_input_tokens(prompts)
    input_tokens *= substance_multiplier(prompts, probe_json["detector"])

    update_probe_attributes(probe, probe_json,
      source: SOURCE,
      attribution: ATTRIBUTION,
      prompts: prompts,
      input_tokens: input_tokens
    )
  end

  # Estimates input tokens accounting for multi-shot cumulative resending.
  # Single-prompt probes: simple token count.
  # Multi-prompt probes: each prompt is resent on all subsequent API calls,
  # so prompt i (0-indexed) is sent (N - i) times total.
  def estimate_probe_input_tokens(prompts)
    return 0 if prompts.empty?
    return TokenEstimator.estimate_tokens(prompts.first) if prompts.size == 1

    n = prompts.size
    prompts.each_with_index.sum do |p, i|
      TokenEstimator.estimate_tokens(p) * (n - i)
    end
  end


  # Determines the runtime token multiplier for probes that expand {substance}.
  # CrystalMethScore probes use a single substance; base probes use 4.
  def substance_multiplier(prompts, detector)
    return 1 unless prompts.any? { |p| p.include?("{substance}") }
    return 1 if detector == "0din.CrystalMethScore"

    BASE_SUBSTANCE_COUNT
  end

  def load_probes_json
    json_path = Rails.root.join(file_path)
    JSON.parse(File.read(json_path))
  rescue Errno::ENOENT
    Rails.logger.error "0DIN probes JSON not found at #{json_path}"
    nil
  rescue JSON::ParserError => e
    Rails.logger.error "Failed to parse 0DIN probes JSON: #{e.message}"
    nil
  rescue SystemCallError => e
    Rails.logger.error "Failed to read 0DIN probes JSON at #{json_path}: #{e.class}: #{e.message}"
    nil
  end

  def sync_variants(data)
    return { industries: 0, subindustries: 0, variants: 0 } unless data.dig("probes").is_a?(Hash)

    industries_cache = {}
    subindustries_cache = {}
    variant_count = 0

    ActiveRecord::Base.transaction do
      data["probes"].each do |probe_name, probe_json|
        next unless probe_json["variants"].is_a?(Hash)

        probe = Probe.find_by(name: probe_name, category: CATEGORY)
        unless probe
          Rails.logger.warn "[OdinProbeSource] Probe not found for variants: #{probe_name}"
          next
        end

        probe_json["variants"].each do |industry_key, subindustries|
          industry_name = industry_key.to_s.humanize.titleize
          industry = industries_cache[industry_key] ||=
            ThreatVariantIndustry.find_or_create_by!(name: industry_name)

          subindustries.each do |subindustry_key, variant_classes|
            subindustry_name = I18n.t(
              "threat_variant_subindustries.names.#{subindustry_key}",
              default: subindustry_key.to_s.humanize.titleize
            )
            cache_key = "#{industry_key}_#{subindustry_key}"
            subindustry = subindustries_cache[cache_key] ||=
              ThreatVariantSubindustry.find_or_create_by!(
                threat_variant_industry: industry,
                name: subindustry_name
              )

            Array(variant_classes).each_with_index do |variant_class, position|
              ThreatVariant.find_or_create_by!(
                probe: probe,
                threat_variant_subindustry: subindustry,
                prompt: variant_class
              ) do |variant|
                variant.position = position + 1
              end
              variant_count += 1
            end
          end
        end
      end
    end

    stats = { industries: industries_cache.size, subindustries: subindustries_cache.size, variants: variant_count }
    Rails.logger.info "[OdinProbeSource] Synced variants: #{stats.inspect}"
    stats
  rescue => e
    Rails.logger.error "[OdinProbeSource] Failed to sync variants: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end

  def record_sync_version(sync_start_time, disable_result, variant_stats = {})
    DataSyncVersion.record_sync(
      SYNC_KEY,
      file_path,
      @valid_probe_names.count,
      {
        sync_start: sync_start_time.iso8601(6),
        disabled_count: disable_result[:disabled_count],
        enabled_count: disable_result[:enabled_count],
        variant_industries: variant_stats[:industries] || 0,
        variant_subindustries: variant_stats[:subindustries] || 0,
        variant_count: variant_stats[:variants] || 0
      }
    )
    Rails.logger.info "Recorded 0DIN probe sync version: #{@valid_probe_names.count} probes, #{variant_stats[:variants] || 0} variants"
  rescue => e
    Rails.logger.error "Failed to record 0DIN probe sync version: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end
end
