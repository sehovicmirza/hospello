# The reception board is the screen a receptionist lives in, so every active
# staff member may read it and work it. Unlike the hotel's configuration, this
# is not policy-setting — accepting a towel request and marking it done is the
# job, not a decision about what the hotel promises.
#
# `destroy?` is deliberately absent (nobody deletes a request; it is cancelled,
# which keeps the history), and there is no create: the only path that makes
# one is a guest confirming a draft.
class ServiceRequestPolicy < ApplicationPolicy
  def index? = active_staff?

  def show? = active_staff?

  # Every status change, and every note. Both are the work itself.
  def transition? = active_staff?

  def note? = active_staff?

  private
    def active_staff?
      user&.active? && (user.staff? || user.hotel_admin?)
    end
end
