# Who may see a hotel's own numbers.
#
# Its record is a Hotel, so it cannot be named `HotelPolicy` (that one exists
# and is platform-admin-only for almost everything) — hence the explicit
# `policy_class:` at the call site. Named for the *screen* rather than the
# record, which is also what it really governs.
#
# **Hotel admins only, unlike most staff screens.** A receptionist reading the
# inbox is doing their job; a receptionist reading "how often did the assistant
# have to hand over to us" is reading a page about their own performance, and
# that is a conversation a manager should choose to have rather than one the
# software starts. The numbers are also about the hotel's commercial use of
# the product — spend against budget, volumes — which is management's.
class HotelAnalyticsPolicy < ApplicationPolicy
  def analytics?
    user&.active? && user.hotel_admin?
  end
end
