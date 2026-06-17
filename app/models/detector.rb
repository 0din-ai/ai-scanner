class Detector < ApplicationRecord
  MITIGATION_BYPASS_DETECTOR_SUFFIX = "MitigationBypass".freeze

  has_many :detector_results, dependent: :destroy
  has_many :reports, through: :detector_results
  has_many :probe_results
  has_many :probes

  validates :name, presence: true, uniqueness: true

  # Default scope to exclude deleted detectors
  default_scope { where(deleted_at: nil) }

  # Scopes for explicit querying
  scope :with_deleted, -> { unscoped }
  scope :deleted_only, -> { unscoped.where.not(deleted_at: nil) }

  def soft_delete!
    update!(deleted_at: Time.current)
  end

  def restore!
    update!(deleted_at: nil)
  end

  def deleted?
    deleted_at.present?
  end

  def mitigation_bypass?
    name&.end_with?(MITIGATION_BYPASS_DETECTOR_SUFFIX)
  end

  def self.ransackable_attributes(auth_object = nil)
    [ "name", "created_at", "id", "updated_at" ]
  end

  def self.ransackable_associations(auth_object = nil)
    [ "detector_results", "reports", "probe_results", "probes" ]
  end
end
