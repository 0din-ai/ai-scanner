class GarakCommunityProbeSource
  include ProbeSyncHelpers

  SYNC_KEY = "garak_probes"
  FILE_PATH = "config/probes/community_probes.json"
  CATEGORY = "garak"
  ATTRIBUTION = "NVIDIA Garak - https://github.com/NVIDIA/garak"

  def needs_sync?
    unless File.exist?(Rails.root.join(FILE_PATH))
      Rails.logger.info "[GarakCommunityProbeSource] Probes file not found at #{FILE_PATH}, skipping sync"
      return false
    end

    DataSyncVersion.needs_sync?(SYNC_KEY, FILE_PATH) ||
      inactive_enabled_probes_need_sync?(source: CATEGORY, data: load_probes_json)
  end

  def sync(sync_start_time)
    Rails.logger.info "Syncing Garak community probes..."
    @valid_probe_names = []
    @enabled_probe_names = []

    garak_data = load_probes_json
    if !garak_data.is_a?(Hash) || !garak_data["probes"].is_a?(Hash)
      Rails.logger.error "Failed to load community probes JSON, skipping sync"
      return { success: false }
    end

    has_errors = garak_data["errors"].present? && garak_data["errors"].respond_to?(:any?) && garak_data["errors"].any?
    if has_errors
      Rails.logger.warn "Community probes JSON contains #{garak_data['errors'].size} extraction errors; will skip disabling outdated probes to avoid removing valid probes"
      garak_data["errors"].each { |err| Rails.logger.warn "  Community probe extraction error: #{sanitize_log_message(err)}" }
    end

    garak_data["probes"].each { |name, probe_json| process_probe(name, probe_json) }

    disable_result = { disabled_count: 0, enabled_count: 0 }
    unless has_errors
      disable_result = disable_outdated_probes(
        source: CATEGORY,
        valid_names: @valid_probe_names,
        enabled_names: @enabled_probe_names
      )
    end

    record_sync_version(sync_start_time, disable_result, has_errors ? garak_data["errors"].size : 0)
    { success: true }
  end

  private

  def process_probe(name, probe_json)
    @valid_probe_names << name
    @enabled_probe_names << name if probe_active?(probe_json)
    probe = Probe.find_or_create_by!(name: name, category: CATEGORY)

    update_probe_attributes(probe, probe_json,
      source: CATEGORY,
      attribution: ATTRIBUTION
    )
  end

  def load_probes_json
    json_path = Rails.root.join(FILE_PATH)
    JSON.parse(File.read(json_path))
  rescue Errno::ENOENT
    Rails.logger.error "Community probes JSON not found at #{json_path}"
    nil
  rescue JSON::ParserError => e
    Rails.logger.error "Failed to parse community probes JSON: #{e.message}"
    nil
  rescue SystemCallError => e
    Rails.logger.error "Failed to read community probes JSON at #{json_path}: #{e.class}: #{e.message}"
    nil
  end

  def record_sync_version(sync_start_time, disable_result, extraction_errors)
    DataSyncVersion.record_sync(
      SYNC_KEY,
      FILE_PATH,
      @valid_probe_names.count,
      {
        sync_start: sync_start_time.iso8601(6),
        disabled_count: disable_result[:disabled_count],
        enabled_count: disable_result[:enabled_count],
        extraction_errors: extraction_errors
      }
    )
    Rails.logger.info "Recorded Garak probe sync version: #{@valid_probe_names.count} probes"
  rescue => e
    Rails.logger.error "Failed to record Garak probe sync version: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end
end
