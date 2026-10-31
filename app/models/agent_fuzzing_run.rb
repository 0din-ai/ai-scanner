# frozen_string_literal: true

class AgentFuzzingRun < ApplicationRecord
  acts_as_tenant :company

  belongs_to :scan
  belongs_to :target
  belongs_to :source_report, class_name: "Report"
  has_many :agent_fuzzing_artifacts, dependent: :destroy

  enum :status, {
    pending: 0,
    running: 1,
    completed: 2,
    failed: 3,
    stopped: 4
  }

  validates :source_report_id, uniqueness: true

  def confirmed_findings
    Array(findings).select { |finding| finding.is_a?(Hash) && finding["disposition"] == "confirmed" }
  end

  def candidate_trials
    Array(trials).select { |trial| trial.is_a?(Hash) && trial["disposition"] == "candidate" }
  end
end
