# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TenantScopedPolicy do
  # TenantScopedPolicy is the base policy for resources scoped by ActsAsTenant.
  # It relies on ActsAsTenant to handle tenant isolation, so permissions are permissive.
  # Used by: Target, Scan, Report, EnvironmentVariable, OutputServer, ProbeUpload, Metadatum

  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let(:user) { create(:user, current_company: company) }
  let(:super_admin) { create(:user, :super_admin, current_company: company) }

  # Use Target as a concrete example of a tenant-scoped resource
  let(:target) { ActsAsTenant.with_tenant(company) { create(:target, company: company) } }
  let(:other_target) { ActsAsTenant.with_tenant(other_company) { create(:target, company: other_company) } }

  describe 'permissive defaults' do
    # TenantScopedPolicy allows all actions because ActsAsTenant handles isolation
    subject { described_class.new(user, target) }

    it { is_expected.to be_index }
    it { is_expected.to be_show }
    it { is_expected.to be_create }
    it { is_expected.to be_update }
    it { is_expected.to be_destroy }
  end

  describe 'Scope' do
    before do
      # Create targets in each company's tenant context
      ActsAsTenant.with_tenant(company) do
        @target1 = create(:target, company: company)
        @target2 = create(:target, company: company)
      end
      ActsAsTenant.with_tenant(other_company) do
        @other_target = create(:target, company: other_company)
      end
    end

    context 'with tenant context set' do
      it 'returns all records (ActsAsTenant handles scoping)' do
        ActsAsTenant.with_tenant(company) do
          scope = described_class::Scope.new(user, Target).resolve
          # ActsAsTenant automatically filters to current tenant
          expect(scope).to include(@target1, @target2)
          expect(scope).not_to include(@other_target)
        end
      end

      it 'respects tenant context for different companies' do
        ActsAsTenant.with_tenant(other_company) do
          other_user = create(:user, current_company: other_company)
          scope = described_class::Scope.new(other_user, Target).resolve
          expect(scope).to include(@other_target)
          expect(scope).not_to include(@target1, @target2)
        end
      end
    end

    context 'without tenant context (super admin bypass)' do
      it 'returns all records when ActsAsTenant is bypassed' do
        ActsAsTenant.without_tenant do
          scope = described_class::Scope.new(super_admin, Target).resolve
          # Without tenant context, all records are returned
          expect(scope).to include(@target1, @target2, @other_target)
        end
      end
    end
  end

  describe 'inheritance' do
    # Verify that concrete policies inherit from TenantScopedPolicy
    it 'TargetPolicy inherits from TenantScopedPolicy' do
      expect(TargetPolicy.superclass).to eq(TenantScopedPolicy)
    end

    it 'ScanPolicy inherits from TenantScopedPolicy' do
      expect(ScanPolicy.superclass).to eq(TenantScopedPolicy)
    end

    it 'ReportPolicy inherits from TenantScopedPolicy' do
      expect(ReportPolicy.superclass).to eq(TenantScopedPolicy)
    end

    it 'EnvironmentVariablePolicy inherits from TenantScopedPolicy' do
      expect(EnvironmentVariablePolicy.superclass).to eq(TenantScopedPolicy)
    end

    it 'OutputServerPolicy inherits from TenantScopedPolicy' do
      expect(OutputServerPolicy.superclass).to eq(TenantScopedPolicy)
    end
  end

  describe 'authorization model' do
    it 'grants all CRUD actions to any authenticated tenant user (intentional flat-permission design)' do
      policy = described_class.new(user, target)
      expect(policy.index?).to be true
      expect(policy.show?).to be true
      expect(policy.create?).to be true
      expect(policy.update?).to be true
      expect(policy.destroy?).to be true
    end

    it 'grants identical permissions to super_admin and regular user within the same tenant' do
      regular_policy = described_class.new(user, target)
      admin_policy = described_class.new(super_admin, target)

      %i[index? show? create? update? destroy?].each do |action|
        expect(regular_policy.public_send(action)).to eq(admin_policy.public_send(action)),
          "Expected #{action} to be the same for regular user and super_admin"
      end
    end

    it 'relies on ActsAsTenant for tenant isolation' do
      ActsAsTenant.with_tenant(company) do
        expect(ActsAsTenant.current_tenant).to eq(company)
      end
    end

    it 'exposes all tenants when ActsAsTenant is bypassed' do
      ActsAsTenant.without_tenant do
        expect(ActsAsTenant.current_tenant).to be_nil
      end
    end
  end
end
