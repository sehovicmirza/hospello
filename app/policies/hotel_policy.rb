# Most Hotel actions are platform-admin-only — Platform::BaseController
# already enforces that for the whole platform namespace, so on those this
# policy is a second, explicit layer rather than the only gate. #update? is
# the one exception: a hotel_admin may also update their OWN hotel from the
# staff side (Staff::HotelSettingsController), where this policy is the only
# gate, since that controller has no role check of its own beyond `authorize`.
class HotelPolicy < ApplicationPolicy
  def index?
    platform_admin?
  end

  def show?
    platform_admin?
  end

  def create?
    platform_admin?
  end

  # A hotel_admin may update their OWN hotel's profile/branding from the
  # staff side (Staff::HotelSettingsController) — the one place this policy
  # is not platform-admin-only. Every other write (identity, platform
  # switches, suspend/activate) stays platform-admin-only.
  def update?
    platform_admin? || hotel_admin_for_own_hotel?
  end

  # Which plan a hotel is on is a commercial decision about the relationship
  # between Hospello and that hotel, so it stays platform-admin-only — unlike
  # #update?, which a hotel_admin may use on their own hotel's branding. A
  # hotel_admin who could move their own hotel onto Revenue would be writing
  # their own invoice.
  def plan?
    platform_admin?
  end

  def suspend?
    platform_admin?
  end

  def activate?
    platform_admin?
  end

  private
    def platform_admin?
      user&.platform_admin? && user.active?
    end

    # Checked even though Staff::HotelSettingsController only ever authorizes
    # Current.hotel (never a hotel id from params) — this is the second,
    # independent layer that keeps the guarantee true even if the controller
    # ever changed, not the only thing enforcing it.
    def hotel_admin_for_own_hotel?
      user&.hotel_admin? && user.active? && user.hotel_id == record.id
    end
end
