# frozen_string_literal: true

# Metadatum is application-global (no acts_as_tenant). The LLM judge's settings live
# here as judge_* rows, and they are written ONLY through SettingsService (validated as
# one unit), so the generic /metadata CRUD refuses them for EVERY actor, super admins
# included. Checked on the stored key AND the submitted one, so renaming a row into or
# out of the judge_* namespace cannot slip past.
#
# Reads follow the Settings page that owns them: only a super admin sees judge_* rows.
class MetadatumPolicy < TenantScopedPolicy
  PROTECTED_PREFIX = "judge_"

  def self.protected_key?(key)
    key.to_s.start_with?(PROTECTED_PREFIX)
  end

  def create?  = super_admin? && keys_permitted?
  def update?  = super_admin? && keys_permitted?
  def destroy? = super_admin? && keys_permitted?

  def show?
    super_admin? || !self.class.protected_key?(record.key)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.all if user&.super_admin?

      # "_" is a LIKE wildcard; escape it so the filter means exactly "judge_".
      pattern = "#{MetadatumPolicy::PROTECTED_PREFIX.gsub(/[\\%_]/) { |c| "\\#{c}" }}%"
      scope.where.not(Metadatum.arel_table[:key].matches(pattern, "\\"))
    end
  end

  private

  def super_admin? = user&.super_admin?

  def keys_permitted?
    keys = [ record.key ]
    keys << record.key_was if record.respond_to?(:key_was)
    keys.compact.none? { |k| self.class.protected_key?(k) }
  end
end
