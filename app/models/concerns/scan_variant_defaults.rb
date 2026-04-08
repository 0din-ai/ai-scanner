module ScanVariantDefaults
  extend ActiveSupport::Concern

  included do
    has_many :scans_threat_variant_subindustries, dependent: :destroy
    has_many :threat_variant_subindustries, through: :scans_threat_variant_subindustries
  end

  def has_threat_variants?
    threat_variant_subindustry_ids.any?
  end
end
