# frozen_string_literal: true

module AgentFuzzing
  # Deployment-owned, never taken from tenant generator variables.
  class Settings
    def self.snapshot(report)
      return {} unless report.scan.agent_fuzzing? && !report.is_variant_report?

      {
        enabled: true,
        provider: ENV.fetch("AGENT_PROVIDER", "openai"),
        model: ENV["AGENT_MODEL"].to_s,
        public_origin: ENV["AGENT_PUBLIC_ORIGIN"].to_s,
        max_steps: 40,
        max_target_calls: 60,
        max_seconds: 900,
        threshold: report.pin_evaluation_threshold!,
        target: report.target.name,
        notes: report.target.description.to_s
      }
    end
  end
end
