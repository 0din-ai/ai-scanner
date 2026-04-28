FactoryBot.define do
  factory :report_debug_log do
    report
    logs { nil }
    tail { nil }
    tail_offset { 0 }
    tail_digest { nil }
    tail_synced_at { nil }
    tail_truncated { false }
  end
end
