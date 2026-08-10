# The reception inbox is the receptionist's screen, not the manager's, so
# this deliberately does NOT subclass HotelConfigurationPolicy: that class
# reserves every write for hotel_admin, which is right for rooms and
# departments and exactly wrong here. Answering a guest is the plain staff
# role's entire job — a policy that let only hotel_admins reply would make
# the "a guest can always reach a human" guarantee depend on a manager
# being at the desk.
#
# Like every other staff policy in this app, this only ever answers "which
# role", never "which hotel": Staff::ConversationsController looks
# conversations up through `Current.hotel.conversations.find`, which 404s
# on another hotel's id before `authorize` is reached at all (see
# test/tenancy/cross_tenant_access_test.rb).
class ConversationPolicy < ApplicationPolicy
  def index?
    active_staff?
  end

  def show?
    active_staff?
  end

  # Posting a reply, writing an internal note, and flipping the AI toggle
  # are all "may this person work this conversation", which is one question
  # with one answer. Named separately anyway so Slice 3+ can diverge — the
  # AI toggle in particular is a plausible candidate for a narrower rule
  # once there is an AI to toggle.
  def reply?
    active_staff?
  end

  def note?
    active_staff?
  end

  def toggle_ai?
    active_staff?
  end

  def resolve?
    active_staff?
  end

  private
    def active_staff?
      user&.active? && (user.staff? || user.hotel_admin?)
    end
end
