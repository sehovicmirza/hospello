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

  def update?
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
end
