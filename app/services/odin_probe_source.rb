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

    DataSyncVersion.needs_sync?(SYNC_KEY, file_path)
  end

  def sync(sync_start_time)
    Rails.logger.info "Syncing 0DIN probes from #{file_path}..."
    @valid_probe_names = []

    data = load_probes_json
    if !data.is_a?(Hash) || !data["probes"].is_a?(Hash)
      Rails.logger.error "Failed to load 0DIN probes JSON, skipping sync"
      return { success: false }
    end

    data["probes"].each { |name, probe_json| process_probe(name, probe_json) }

    disable_result = disable_outdated_probes(source: SOURCE, valid_names: @valid_probe_names)
    record_sync_version(sync_start_time, disable_result)
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
    probe = Probe.find_or_create_by!(name: name, category: CATEGORY)

    prompts = probe_json["prompts"] || []
    input_tokens = prompts.sum { |p| TokenEstimator.estimate_tokens(p) }
    input_tokens *= substance_multiplier(prompts, probe_json["detector"])

    update_probe_attributes(probe, probe_json,
      source: SOURCE,
      attribution: ATTRIBUTION,
      prompts: prompts,
      input_tokens: input_tokens
    )
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

  def record_sync_version(sync_start_time, disable_result)
    DataSyncVersion.record_sync(
      SYNC_KEY,
      file_path,
      @valid_probe_names.count,
      {
        sync_start: sync_start_time.iso8601(6),
        disabled_count: disable_result[:disabled_count],
        enabled_count: disable_result[:enabled_count]
      }
    )
    Rails.logger.info "Recorded 0DIN probe sync version: #{@valid_probe_names.count} probes"
  rescue => e
    Rails.logger.error "Failed to record 0DIN probe sync version: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end
end
