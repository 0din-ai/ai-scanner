# frozen_string_literal: true

# All tenant members have equal access to tenant-scoped resources.
# Cross-tenant isolation is enforced by ActsAsTenant, not this policy.
class TenantScopedPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    true
  end

  def create?
    true
  end

  def update?
    true
  end

  def destroy?
    true
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      # ActsAsTenant automatically scopes queries to current tenant.
      # No additional filtering needed - just return all records.
      scope.all
    end
  end
end
