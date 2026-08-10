# The reception board's live-update transport — the request-side counterpart
# of HotelInboxChannel, and it repeats that class's ownership check rather
# than sharing it because the two differ in exactly one place (`:requests`
# instead of `:inbox`) and a shared superclass parameterised on that one token
# would make the check harder to read than to re-verify.
#
# The reasoning is HotelInboxChannel's in full: Turbo's signature proves a
# stream name was not tampered with, not that this connection is allowed to
# hold it, so the connection's own current_user must be an active,
# non-platform staff member of an unsuspended hotel *and* the name must be
# that hotel's own requests stream. A cable connection outlives the request
# that opened it, which is why the active/suspended checks are here at all.
class HotelRequestsChannel < ActionCable::Channel::Base
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

      # Reusing the exact algorithm that produced the client's name rather
      # than a second, hand-written decoding of it — see HotelInboxChannel.
      self.class.send(:stream_name_from, [ current_user.hotel, :requests ]) == stream_name
    end

    def staff_user_of_an_active_hotel?
      current_user.present? &&
        !current_user.platform_admin? &&
        current_user.active? &&
        current_user.hotel&.active?
    end
end
