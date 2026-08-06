class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  # Deliberately NOT TenantScoped: hotel_id is nullable because platform admins
  # belong to no hotel. See test/tenancy/tenant_declaration_test.rb.
  belongs_to :hotel, optional: true

  enum :role, { staff: 0, hotel_admin: 1, platform_admin: 2 }

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validate :hotel_membership_matches_role

  scope :active, -> { where(active: true) }

  # A session may only be started while the account is active and, for hotel
  # users, while their hotel is not suspended.
  def can_sign_in?
    return false unless active?
    return true if platform_admin?

    hotel.present? && hotel.active?
  end

  private
    def hotel_membership_matches_role
      if platform_admin?
        errors.add(:hotel, "must be blank: platform admins must not belong to a hotel") if hotel_id.present?
      elsif hotel_id.blank?
        errors.add(:hotel, "must be present: staff and hotel admins must belong to a hotel")
      end
    end
end
