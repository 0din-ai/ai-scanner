class VariantProbeMapper < ApplicationService
  def initialize(base_probe_names, subindustry_ids)
    @base_probe_names = Array(base_probe_names)
    @subindustry_ids = Array(subindustry_ids)
  end

  def call
    return [] if @subindustry_ids.empty? || @base_probe_names.empty?

    probe_classes = @base_probe_names.map { |name| name.split(".").last }

    probes = Probe.where(name: probe_classes).index_by(&:name)

    probe_ids = probes.values.map(&:id)
    return [] if probe_ids.empty?

    variants = ThreatVariant
      .joins(:threat_variant_subindustry)
      .where(
        probe_id: probe_ids,
        threat_variant_subindustry_id: @subindustry_ids
      )

    variants.map { |v| "0din_variants.#{v.prompt}" }.uniq
  end
end
