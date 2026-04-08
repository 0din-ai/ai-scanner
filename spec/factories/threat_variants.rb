FactoryBot.define do
  factory :threat_variant do
    sequence(:prompt) { |n| "Variant_TAG_Industry_Subindustry_#{n}" }
    probe
    threat_variant_subindustry
  end
end
