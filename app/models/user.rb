class User < ApplicationRecord
  include Activatable

  # has_secure_password only requires a password to be *present* — "a" is
  # accepted with no minimum length on either screen that creates a user
  # (Platform::HotelAdminsController, Staff::UsersController). Both inherit
  # this from the model instead of validating it twice. allow_blank: true
  # keeps this from firing on every plain `update` of an existing user —
  # password is a virtual attribute, nil unless a password change was
  # actually submitted (Staff::UsersController's #update, for instance, only
  # ever touches `active`).
  MINIMUM_PASSWORD_LENGTH = 8

  has_secure_password
  has_many :sessions, dependent: :destroy

  validates :password, length: { minimum: MINIMUM_PASSWORD_LENGTH }, allow_blank: true

  # Deliberately NOT TenantScoped: hotel_id is nullable because platform admins
  # belong to no hotel. See test/tenancy/tenant_declaration_test.rb.
  belongs_to :hotel, optional: true

  enum :role, { staff: 0, hotel_admin: 1, platform_admin: 2 }

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  # DB-unique already (see the users migration); this turns a raw
  # ActiveRecord::RecordNotUnique into a normal validation error so a
  # duplicate email re-renders the form with a clear message instead of
  # raising — mirrors Hotel#slug's uniqueness validation.
  validates :email_address, uniqueness: true

  validate :hotel_membership_matches_role

  scope :active, -> { where(active: true) }

  # User is exempt from acts_as_tenant (platform admins belong to no hotel), so a
  # bare User relation crosses hotels without raising. Inside a hotel context read
  # users through this scope or through Current.hotel.users.
  scope :for_hotel, ->(hotel) { where(hotel: hotel) }

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
