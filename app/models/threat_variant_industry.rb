class ThreatVariantIndustry < ApplicationRecord
  has_many :threat_variant_subindustries, dependent: :destroy
  has_many :threat_variants, through: :threat_variant_subindustries

  validates :name, presence: true, uniqueness: true

  def for_select
    [ name, id ]
  end
end
