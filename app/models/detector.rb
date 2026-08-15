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

  # Canonical presentation for a detector identifier, used by every surface that names
  # one -- report detector statistics, scan definitions, probe pages and the controllers
  # that build category lists.
  #
  # The friendly name comes from the last segment ("0din.MitigationBypass" ->
  # "Generic Mitigation Bypass Checks"), which means two detectors from different
  # namespaces can share a label. That is why #qualifier_for exists: without it, a report
  # showed two identically-named rows carrying different numerators and denominators, and
  # nothing on screen explained why they differed.
  def self.display_label(detector_name)
    return "Unknown" if detector_name.blank?

    short = detector_name.to_s.split(".").last
    I18n.t("detectors.names.#{short}", default: short)
  end

  # The identifier to show beside the label, or nil when the label already conveys it.
  def self.qualifier_for(detector_name)
    return nil if detector_name.blank?

    full = detector_name.to_s
    full == display_label(full) ? nil : full
  end

  def display_label
    self.class.display_label(name)
  end

  def qualifier
    self.class.qualifier_for(name)
  end

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
