# frozen_string_literal: true

module Reports
  class RunningStats
    CACHE_TTL = 1.hour

    class << self
      def company(company_id)
        base_scope = Report.where(company_id: company_id).active
        stats_for(base_scope)
      end

      def global
        ActsAsTenant.without_tenant do
          base_scope = Report.active
          stats_for(base_scope).merge(
            priority: base_scope.where(parent_report_id: nil).joins(:scan).where(scans: { priority: true }).count
          )
        end
      end

      def write_company(company_id)
        stats = company(company_id)
        Rails.cache.write(cache_key_for(company_id), stats, expires_in: CACHE_TTL)
        stats
      end

      def write_global
        stats = global
        Rails.cache.write(cache_key_for(:global), stats, expires_in: CACHE_TTL)
        stats
      end

      def cache_key_for(identifier)
        "running_scans_stats:#{identifier}"
      end

      private

      def stats_for(base_scope)
        scans = base_scope.where(parent_report_id: nil).count
        variants = base_scope.where.not(parent_report_id: nil).count
        { scans: scans, variants: variants, total: scans + variants }
      end
    end
  end
end
