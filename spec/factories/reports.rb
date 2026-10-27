FactoryBot.define do
  factory :report do
    transient do
      skip_validate { false }
    end

    company do
      associated_company = if __override_names__.include?(:scan)
        scan&.company
      elsif __override_names__.include?(:target)
        target&.company
      end
      associated_company || ActsAsTenant.current_tenant || association(:default_company, strategy: :create)
    end
    scan { association :complete_scan, company: company }
    target { association :target, company: company }

    uuid { SecureRandom.uuid }
    name { "Report for #{target&.name || 'Unknown'}" }
    status { :pending }

    trait :running do
      status { :running }
    end

    trait :processing do
      status { :processing }
    end

    trait :completed do
      status { :completed }
    end

    trait :failed do
      status { :failed }
    end

    trait :stopped do
      status { :stopped }
    end
  end
end
