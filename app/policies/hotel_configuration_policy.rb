# Shared read/write split for the hotel-configuration resources this task
# adds (rooms, departments, request categories): any active staff member of
# the hotel may view; only an active hotel_admin may create, edit, or
# delete. Not used directly — subclassed per resource (RoomPolicy,
# DepartmentPolicy, RequestCategoryPolicy) so Pundit's default class-name
# inference (`RoomPolicy` for a `Room` record) keeps working, and so each
# can diverge later if a resource ever needs its own rule. QrCodePolicy
# (Task 6) also subclasses this for the same "any active staff member may
# read" half — the QR code has no create/update/destroy at all, so it only
# ever uses #show? and adds its own #print?.
#
# Cross-tenant access is never reached here at all: every staff controller
# looks records up through `Current.hotel.<association>.find`, which 404s on
# a foreign id before `authorize` is even called (see
# test/tenancy/cross_tenant_access_test.rb). This policy only ever answers
# "which role", never "which hotel".
class HotelConfigurationPolicy < ApplicationPolicy
  def index?
    active_staff?
  end

  def show?
    active_staff?
  end

  def create?
    active_hotel_admin?
  end

  def update?
    active_hotel_admin?
  end

  def destroy?
    active_hotel_admin?
  end

  private
    def active_staff?
      user&.active? && (user.staff? || user.hotel_admin?)
    end

    def active_hotel_admin?
      user&.active? && user.hotel_admin?
    end
end
