# frozen_string_literal: true

class AgentFuzzingArtifact < ApplicationRecord
  acts_as_tenant :company
  belongs_to :agent_fuzzing_run
end
