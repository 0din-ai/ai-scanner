FactoryBot.define do
  factory :scan do
    company { ActsAsTenant.current_tenant || association(:default_company, strategy: :create) }
    name { Faker::App.name }
    uuid { SecureRandom.uuid }

    trait :with_targets do
      after(:build) do |scan|
        scan.targets << create_list(:target, 2, company: scan.company)
      end
    end

    trait :with_probes do
      after(:build) do |scan|
        scan.probes << create_list(:probe, 2)
      end
    end

    trait :with_recurrence do
      recurrence { IceCube::Rule.daily.to_hash.to_json }

      after(:build) do |scan|
        scan.instance_variable_set('@run_next_scheduled_update', true)
      end
    end

    trait :with_output_server do
      output_server { association :output_server, company: company }
    end

    factory :complete_scan do
      with_targets
      with_probes
    end
  end
end
