# Staff accounts are administrative data — who can sign in, at what
# privilege level — not a hotel-configuration resource plain staff should
# ever browse. Unlike HotelConfigurationPolicy (rooms, departments,
# categories), every action here is hotel_admin-only, including reading the
# roster: a plain staff user gets 403 on every users route, no read access
# at all.
class UserPolicy < ApplicationPolicy
  def index?
    active_hotel_admin?
  end

  def new?
    active_hotel_admin?
  end

  def create?
    active_hotel_admin?
  end

  def edit?
    active_hotel_admin?
  end

  def update?
    active_hotel_admin?
  end

  private
    def active_hotel_admin?
      user&.active? && user.hotel_admin?
    end
end
