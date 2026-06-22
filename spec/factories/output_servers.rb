FactoryBot.define do
  factory :output_server do
    association :company
    sequence(:name) { |n| "#{Faker::App.name}_#{n}" }
    server_type { 'splunk' }
    # Deterministic non-blocked (TEST-NET-3) address so the host-SSRF validation passes —
    # Faker's random IPs can land in private/blocked ranges and flake.
    host { '203.0.113.10' }
    port { 8088 }
    protocol { 'https' }
    endpoint_path { '/services/collector' }
    enabled { true }

    trait :with_credentials do
      access_token { SecureRandom.hex(16) }
      username { 'admin' }
      password { 'password' }
    end

    trait :with_additional_settings do
      additional_settings { '{"verify_ssl": false, "batch_size": 10}' }
    end

    factory :splunk_server do
      server_type { 'splunk' }
    end

    factory :rsyslog_server do
      server_type { 'rsyslog' }
      protocol { 'tcp' }
      port { 514 }
      endpoint_path { nil }
    end
  end
end
