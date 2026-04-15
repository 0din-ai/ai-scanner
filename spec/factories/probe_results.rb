FactoryBot.define do
  factory :probe_result do
    association :report
    association :probe
    association :detector

    attempts { [ { "prompt" => "test prompt", "response" => "test response" } ] }
    max_score { rand(1..5) }
    passed { rand(0..10) }
    total { rand(10..20) }
    any_detector_passed { passed.to_i.positive? }

    trait :high_score do
      max_score { 5 }
      passed { 10 }
      total { 10 }
    end

    trait :low_score do
      max_score { 1 }
      passed { 0 }
      total { 10 }
    end

    trait :nil_attempts do
      attempts { nil }
    end
  end
end
