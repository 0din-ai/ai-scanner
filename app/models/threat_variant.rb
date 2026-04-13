class ThreatVariant < ApplicationRecord
  belongs_to :probe
  belongs_to :threat_variant_subindustry
  has_one :threat_variant_industry, through: :threat_variant_subindustry

  validates :prompt, presence: true, uniqueness: { scope: :probe_id }

  scope :by_industry, ->(industry) {
    joins(:threat_variant_subindustry)
    .where(threat_variant_subindustries: { threat_variant_industry_id: industry.id })
  }
end
