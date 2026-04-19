FactoryBot.define do
  factory :report_pdf do
    report
    status { :pending }

    trait :completed do
      status { :completed }
      file_path { Rails.root.join("storage", "pdfs", "report_#{report&.id || 0}.pdf").to_s }
    end

    trait :downloaded do
      completed
      downloaded_at { Time.current }
    end
  end
end
