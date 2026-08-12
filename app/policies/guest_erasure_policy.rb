# Erasing a guest's data is platform-admin-only, and unlike most of this
# namespace's policies that is not merely a second layer over
# Platform::BaseController — it is the answer to "should a hotel be able to
# do this themselves?", which is no.
#
# A hotel_admin deleting a guest's transcript is indistinguishable, from the
# outside, from a hotel destroying a complaint. The request has to arrive at
# whoever runs Hospello, be recorded there, and be actioned there.
#
# A headless policy (`authorize :guest_erasure, :create?`): there is no
# record to authorize against that would change the answer. It is the same
# answer for every hotel and every guest.
class GuestErasurePolicy < ApplicationPolicy
  def index? = platform_admin?

  def new? = platform_admin?

  def create? = platform_admin?

  private
    def platform_admin? = user&.platform_admin? && user.active?
end
