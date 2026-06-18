class EnvironmentVariable < ApplicationRecord
  acts_as_tenant :company
  belongs_to :target, optional: true

  encrypts :env_value, key_provider: Encryption::TenantKeyProvider.new

  validates :env_name, presence: true,
                      format: { with: /\A[A-Za-z_][A-Za-z0-9_]*\z/, message: "must be a valid environment variable name" }
  validates :env_name, uniqueness: { scope: [ :company_id, :target_id ] }
  validates :env_value, presence: true
  # garak detector scores are 0.0–1.0, so the eval threshold domain is [0, 1].
  # Guard at write time so a non-numeric or out-of-range value can never be
  # saved (a bad value would silently become 0.0 via to_f → ASR 100%). Only
  # applies to EVALUATION_THRESHOLD; other env vars/secrets accept any value.
  validates :env_value,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
            if: -> { env_name == EVALUATION_THRESHOLD_ENV_NAME }

  scope :global, -> { where(target_id: nil) }

  EVALUATION_THRESHOLD_ENV_NAME = "EVALUATION_THRESHOLD"
  # garak's ThresholdEvaluator default when --eval_threshold is not passed.
  GARAK_DEFAULT_EVAL_THRESHOLD = 0.5

  # Effective garak eval threshold for a target: the same value
  # RunGarakScan#evaluation_threshold passes via --eval_threshold (target
  # override, else global), else garak's default. Keep this lookup consistent
  # with RunGarakScan#evaluation_threshold so per-attempt success agrees with
  # the aggregate ASR. Requires the tenant to be set (reads encrypted env_value).
  def self.evaluation_threshold_for(target)
    env_var = target.environment_variables.find_by(env_name: EVALUATION_THRESHOLD_ENV_NAME) ||
      global.find_by(env_name: EVALUATION_THRESHOLD_ENV_NAME)
    value = env_var&.env_value
    value.present? ? value.to_f : GARAK_DEFAULT_EVAL_THRESHOLD
  end

  def self.ransackable_attributes(auth_object = nil)
    [ "created_at", "env_name", "id", "target_id", "updated_at" ]
  end

  def self.ransackable_associations(auth_object = nil)
    [ "target" ]
  end
end
