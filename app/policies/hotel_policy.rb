# Every Hotel action in this slice is platform-admin-only — the base
# controller already enforces that for the whole namespace, so this policy is
# a second, explicit layer rather than the only gate. It also gives Task 3 a
# named `update?` to extend (or replace) once a hotel_admin may edit their own
# hotel from the staff side.
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
