# frozen_string_literal: true

class UserPolicy < ApplicationPolicy
  # Match the membership-based scope even when a colleague is active elsewhere.
  def same_company?
    user.current_company_id.present? && record.memberships.exists?(company_id: user.current_company_id)
  end

  def index?
    true # Scope handles filtering by company
  end

  def show?
    super_admin? || record == user || same_company?
  end

  def create?
    super_admin?
  end

  def update?
    return true if super_admin?
    return false if record.super_admin?
    record == user
  end

  def destroy?
    return false if record == user # Can't delete self
    return false if record.super_admin? # Can't delete super admins
    super_admin?
  end

  # Custom permissions

  # Can this user impersonate the target user?
  def impersonate?
    super_admin? && !record.super_admin? && record != user
  end

  # Can this user toggle the super_admin flag?
  def manage_super_admin_flag?
    super_admin?
  end

  # Can this user assign users to different companies?
  def manage_company?
    super_admin?
  end

  # UI visibility helpers

  def see_company_column?
    super_admin?
  end

  def see_super_admin_column?
    super_admin?
  end

  # Used for column header visibility (class-level check, no record needed)
  def see_impersonate_column?
    super_admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if super_admin?
        ActsAsTenant.without_tenant { scope.includes(:current_company) }
      else
        # Keep self-service available to legacy accounts awaiting assignment, but
        # do not expose other membership-free users when no company is active.
        peers = if user.current_company_id.present?
          scope.where(id: Membership.where(company_id: user.current_company_id).select(:user_id))
        else
          scope.none
        end
        scope.where(id: user.id).or(peers)
      end
    end
  end
end
