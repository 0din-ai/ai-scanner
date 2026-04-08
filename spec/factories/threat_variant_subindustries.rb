FactoryBot.define do
  factory :threat_variant_subindustry do
    sequence(:name) { |n| "Subindustry #{n}" }
    threat_variant_industry
  end
end
