# frozen_string_literal: true

class User < ApplicationRecord
  # M:N relationship with companies via memberships
  has_many :memberships, dependent: :destroy
  has_many :companies, through: :memberships

  # Current company for ActsAsTenant context
  belongs_to :current_company, class_name: "Company", optional: true

  validates :time_zone, inclusion: { in: ActiveSupport::TimeZone.all.map(&:name), allow_blank: true }

  # Devise modules (engine may add :omniauthable)
  devise :database_authenticatable, :recoverable, :rememberable,
         :validatable, :lockable

  # Super admin scopes and methods
  scope :super_admins, -> { where(super_admin: true) }
  scope :regular_admins, -> { where(super_admin: false) }

  def super_admin?
    super_admin
  end

  # Alias for backwards compatibility and clarity
  def company
    current_company
  end

  # Setter alias for backwards compatibility (used in forms and controllers)
  def company=(value)
    self.current_company = value
    # Also ensure membership exists when setting company
    if value && !memberships.exists?(company: value)
      memberships.build(company: value)
    end
  end

  # Set default current_company if not set
  def ensure_current_company!
    return if current_company_id.present?
    first_company = companies.first
    update!(current_company: first_company) if first_company
  end

  def self.ransackable_attributes(auth_object = nil)
    %w[current_company_id external_id created_at email id super_admin time_zone updated_at]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[current_company companies memberships]
  end
end
