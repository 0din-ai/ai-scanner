class GenerateVariantReportsJob < ApplicationJob
  queue_as :default

  def perform(parent_report_id)
    parent_report = Report.find(parent_report_id)

    ActsAsTenant.with_tenant(parent_report.company) do
      scan = parent_report.scan

      return if parent_report.is_variant_report?
      return unless scan.has_threat_variants?

      passed_probes = extract_passed_probes(parent_report)
      return if passed_probes.empty?

      Rails.logger.info("Generating variant report for #{passed_probes.count} passed probes")

      subindustry_ids = scan.threat_variant_subindustry_ids
      return if subindustry_ids.empty?

      create_combined_variant_report(parent_report, passed_probes, subindustry_ids)
    end
  end

  private

  def extract_passed_probes(report)
    report.probe_results.where(any_detector_passed: true).includes(:probe).filter_map { |pr|
      pr.probe&.full_name
    }.uniq
  end

  def create_combined_variant_report(parent_report, probe_names, subindustry_ids)
    all_variant_probes = VariantProbeMapper.new(probe_names, subindustry_ids).call

    if all_variant_probes.empty?
      Rails.logger.info("No variants found for any probes with subindustries #{subindustry_ids}")
      return
    end

    Rails.logger.info("Creating combined variant report with #{all_variant_probes.count} total variants")

    child_report = Report.create!(
      scan: parent_report.scan,
      target: parent_report.target,
      company: parent_report.company,
      parent_report_id: parent_report.id,
      status: :pending,
      name: "#{parent_report.name} - All Variants"
    )

    probe_names.each do |probe_name|
      probe_class = probe_name.split(".").last
      probe = Probe.find_by(name: probe_class)
      child_report.variant_probes << probe if probe
    end

    RunGarakScan.new(child_report).call
  rescue ActiveRecord::RecordNotUnique
    Rails.logger.info("Variant report already exists for parent #{parent_report.id}, skipping")
  rescue StandardError => e
    child_report&.update(status: :failed) if child_report&.persisted?
    Rails.logger.error("Failed to create combined variant report: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    raise
  end
end
