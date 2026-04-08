FactoryBot.define do
  factory :threat_variant_industry do
    sequence(:name) { |n| "Industry #{n}" }
  end
end
