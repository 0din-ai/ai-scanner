require_relative "../../lib/scanner/configuration"
# Defaults are set in Configuration#initialize — no explicit config needed for OSS

# After a parent report finishes processing, generate variant reports
# if the scan has threat variant subindustries selected.
Scanner.register_hook(:after_report_process) do |context|
  report = context[:report]
  next unless report.completed?
  next if report.is_variant_report?
  next unless report.scan.has_threat_variants?

  GenerateVariantReportsJob.perform_later(report.id)
end
