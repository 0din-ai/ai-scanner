require "rails_helper"

# Guards the fix for the cross-tenant ASR aggregate leak: the raw-SQL average must
# only reflect the current tenant's reports, and must fail closed with no tenant.
RSpec.describe Stats::AverageAsrScore do
  it "scopes the average attack success rate to the current tenant" do
    company_a = create(:company)
    company_b = create(:company)

    ActsAsTenant.with_tenant(company_a) do
      r = create(:report, company: company_a)
      create(:probe_result, report: r, passed: 9, total: 10) # 90%
    end
    ActsAsTenant.with_tenant(company_b) do
      r = create(:report, company: company_b)
      create(:probe_result, report: r, passed: 1, total: 10) # 10%
    end

    ActsAsTenant.with_tenant(company_a) do
      expect(described_class.new.average_attack_success_rate).to eq(90.0)
    end
    ActsAsTenant.with_tenant(company_b) do
      expect(described_class.new.average_attack_success_rate).to eq(10.0)
    end
  end

  it "fails closed when there is no current tenant, matching no reports rather than leaking any" do
    company = create(:company)
    ActsAsTenant.with_tenant(company) do
      r = create(:report, company: company)
      create(:probe_result, report: r, passed: 5, total: 10)
    end

    ActsAsTenant.without_tenant do
      # company_id: nil means the WHERE clause matches zero rows (company_id = NULL is
      # never true in SQL) -- the same "nothing measurable" outcome as no reports at all,
      # so it is nil rather than a false zero, not a leak of the tenant's real 50%.
      expect(described_class.new.average_attack_success_rate).to be_nil
    end
  end

  it "fails closed for the time series too (not just the scalar) when there is no tenant" do
    company = create(:company)
    ActsAsTenant.with_tenant(company) do
      r = create(:report, company: company)
      create(:probe_result, report: r, passed: 9, total: 10)
    end

    ActsAsTenant.without_tenant do
      result = described_class.new(days: 30).call
      expect(result[:data][:rates]).to all(eq(0.0))
    end
  end
end
