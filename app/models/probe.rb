class Probe < ApplicationRecord
  include ProbeOssDefaults

  has_and_belongs_to_many :scans
  has_and_belongs_to_many :techniques
  has_and_belongs_to_many :taxonomy_categories
  has_many :probe_results
  has_many :threat_variants, dependent: :destroy
  belongs_to :detector, optional: true

  scope :enabled, -> { where(enabled: true) }
  scope :by_release_date, -> { order(release_date: :asc) }

  # Enum declarations live in the base model because the DB columns exist regardless
  # and base app code (stats serializer, probes controller, disclosure stats) depends on
  # the class methods (Probe.disclosure_statuses, Probe.social_impact_scores).
  enum :disclosure_status, {
    "0-day" => 0,
    "n-day" => 1
  }

  enum :social_impact_score, {
    "Minimal Risk" => 1,
    "Moderate Risk" => 2,
    "Significant Risk" => 3,
    "High Risk" => 4,
    "Critical Risk" => 5
  }

  validates :name, presence: true, uniqueness: true
  validates :category, presence: true
  validates :source, presence: true

  def self.ransackable_attributes(auth_object = nil)
    [ "detector_id", "created_at", "description", "disclosure_status", "id", "name", "updated_at", "guid", "summary", "social_impact_score", "techniques", "release_date", "modified_date", "source" ]
  end

  def self.ransackable_associations(auth_object = nil)
    [ "scans", "techniques", "detector", "taxonomy_categories" ]
  end

  def self.by_category(category_type)
    case category_type.to_sym
    when :cm
      where("name LIKE ?", "%CM")
    when :hp
      where("name LIKE ?", "%HP")
    when :generic
      where("name NOT LIKE ? AND name NOT LIKE ?", "%CM", "%HP")
    else
      none
    end
  end

  def for_select
    [ name, id ]
  end

  def full_name
    # Garak probe names already include the module (e.g., "dan.Dan_11_0")
    # Engine probe names are just the class name (e.g., "SomeProbe")
    return name if source == "garak"

    "#{category}.#{name}"
  end
end
