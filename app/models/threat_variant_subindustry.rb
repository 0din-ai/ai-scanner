class ThreatVariantSubindustry < ApplicationRecord
  belongs_to :threat_variant_industry
  has_many :threat_variants, dependent: :destroy

  validates :name, presence: true, uniqueness: { scope: :threat_variant_industry_id }

  def for_select
    [ name, id ]
  end
end
