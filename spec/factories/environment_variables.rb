FactoryBot.define do
  factory :environment_variable do
    sequence(:env_name) { |n| "ENV_VAR_#{n}" }
    env_value { "test_value" }
    company { target&.company || ActsAsTenant.current_tenant || association(:default_company, strategy: :create) }

    trait :with_target do
      association :target
    end

    factory :global_environment_variable do
      target { nil }
    end
  end
end
