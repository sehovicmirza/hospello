# The reception inbox's live-update transport, and the staff-side
# counterpart of ConversationChannel — see that class for the full
# reasoning this shares: Turbo::StreamsChannel accepts ANY validly-signed
# stream name from ANY connection with no per-connection ownership check,
# which is exactly the gap a leaked or screenshotted signed stream name
# would need. Turbo's signature only proves a name wasn't tampered with; it
# says nothing about who is allowed to hold it.
#
# What this adds on top of that signature: the connection's own
# current_user (identified in ApplicationCable::Connection from the signed
# session cookie, never from anything the client sends here) must be an
# active, non-platform staff member of a hotel that is not suspended, and
# the stream name must be that hotel's own inbox stream. A staff member at
# hotel A holding hotel B's signed stream name gets nothing.
#
# The suspension and active checks mirror Staff::BaseController's
# #require_staff_user rather than restating a subset of it: a cable
# connection outlives the request that opened it, so a staff member
# deactivated — or a hotel suspended — five minutes ago must not keep
# receiving that hotel's guest messages over a socket nobody thought to
# close.
class HotelInboxChannel < ActionCable::Channel::Base
  extend Turbo::Streams::Broadcasts
  extend Turbo::Streams::StreamName
  include Turbo::Streams::StreamName::ClassMethods

  def subscribed
    stream_name = verified_stream_name_from_params

    if stream_name && subscription_allowed?(stream_name)
      stream_from stream_name
    else
      reject
    end
  end

  private
    def subscription_allowed?(stream_name)
      return false unless staff_user_of_an_active_hotel?

      # self.class.send(...): #stream_name_from is private on
      # Turbo::Streams::StreamName, extended here the same way
      # Turbo::StreamsChannel extends it onto itself. Reusing the exact
      # algorithm that produced the client's name — rather than a second,
      # hand-written decoding of it — is what keeps this correct if that
      # algorithm ever changes.
      self.class.send(:stream_name_from, [ current_user.hotel, :inbox ]) == stream_name
    end

    def staff_user_of_an_active_hotel?
      current_user.present? &&
        !current_user.platform_admin? &&
        current_user.active? &&
        current_user.hotel&.active?
    end
end
