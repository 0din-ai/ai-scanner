# frozen_string_literal: true

module Retention
  # OSS retention strategy: fixed retention period for all companies.
  # Configurable via RETENTION_DAYS environment variable (default: 90 days).
  #
  # Usage:
  #   result = Retention::SimpleStrategy.call
  #   # => { companies_processed: 5, reports_deleted: 42, errors: [], timestamp: ... }
  #
  class SimpleStrategy < ApplicationService
    CLEANUP_SAFE_STATUSES = %w[completed failed stopped].freeze
    BATCH_SIZE = 100
    DEFAULT_RETENTION_DAYS = 90

    def call
      stats = {
        companies_processed: 0,
        reports_deleted: 0,
        errors: [],
        timestamp: Time.current
      }

      cutoff_date = retention_days.days.ago

      Company.find_each do |company|
        process_company(company, cutoff_date, stats)
      end

      stats
    end

    private

    def retention_days
      # Strict Integer(), not String#to_i. This setting decides what gets DELETED, and
      # to_i reads a partially-numeric "5oops" as 5 and a decimal "1.5" as 1 -- so a
      # typo would quietly shorten retention rather than being rejected. Blank,
      # unparseable and non-positive values all fall back to the default.
      days = Integer(ENV["RETENTION_DAYS"].to_s.strip, exception: false).to_i
      days = DEFAULT_RETENTION_DAYS unless days.positive?
      [ days, 1 ].max
    end

    def process_company(company, cutoff_date, stats)
      ActsAsTenant.with_tenant(company) do
        reports_to_delete = Report
          .where(status: CLEANUP_SAFE_STATUSES)
          .where("created_at < ?", cutoff_date)

        count = reports_to_delete.count
        return if count.zero?

        Rails.logger.info "[RetentionCleanup] Company #{company.id}: " \
          "deleting #{count} reports older than #{cutoff_date.to_date}"

        reports_to_delete.find_each(batch_size: BATCH_SIZE, &:destroy)

        stats[:companies_processed] += 1
        stats[:reports_deleted] += count
      end
    rescue StandardError => e
      Rails.logger.error "[RetentionCleanup] Error processing company #{company.id}: #{e.message}"
      stats[:errors] << { company_id: company.id, message: e.message }
    end
  end
end
