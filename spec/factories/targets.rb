FactoryBot.define do
  factory :target do
    association :company
    sequence(:name) { |n| "Target #{Faker::Internet.domain_name}-#{n}" }
    model_type { 'OpenAIGenerator' }
    model { 'gpt-3.5-turbo' }
    description { Faker::Lorem.paragraph }

    trait :with_json_config do
      json_config { '{"temperature": 0.7, "max_tokens": 100}' }
    end

    trait :deleted do
      deleted_at { Time.current }
    end

    trait :validating do
      status { :validating }
    end

    trait :good do
      status { :good }
      validation_text { 'Target validated successfully - received 3 response(s). Sample response: Hello, how can I help you? Evaluation: 3/3 attempts passed.' }
    end

    trait :bad do
      status { :bad }
      validation_text { 'Target validation failed: No responses received. Evaluation: 0/3 attempts passed.' }
    end

    trait :with_token_rate do
      tokens_per_second { 25.5 }
      tokens_per_second_sample_count { 3 }
    end

    trait :webchat do
      target_type { :webchat }
      web_config do
        {
          'url' => 'https://example.com/chat',
          'selectors' => {
            'input_field' => '#chat-input',
            'response_container' => '.chat-messages'
          }
        }
      end
    end

    trait :with_scans do
      after(:build) do |target|
        target.scans << create_list(:scan, 2, company: target.company)
      end
    end
  end
end
