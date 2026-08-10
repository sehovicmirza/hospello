# The guest chat's live-update transport. Built on Turbo's own documented
# extension point (see Turbo::StreamsChannel's class comment in the
# turbo-rails gem: "In case if custom behavior is desired, one can create
# their own channel...") rather than reusing Turbo::StreamsChannel
# directly — that channel accepts ANY validly-signed stream name from ANY
# connection, with no per-connection ownership check at all. That's exactly
# the gap a guest exploiting a leaked or guessed signed-stream-name (an old
# bookmark, a shared screenshot, a stale link to a resolved conversation)
# would need. #subscription_allowed? closes it: even a name whose signature
# verifies is refused unless the connection's own current_guest_session
# (identified in ApplicationCable::Connection from the guest's signed
# cookie — never from anything the client sends over the wire here) is the
# guest_session that conversation actually belongs to.
#
# Broadcasting still reaches subscribers here even though production code
# calls Turbo::StreamsChannel.broadcast_append_to (see Conversation#broadcast_new_message)
# rather than this class: both compute the same underlying pub/sub topic
# from the same [conversation] streamable (Turbo::Streams::StreamName#stream_name_from),
# and ActionCable's pub/sub is keyed on that topic string alone, not on
# which Channel subclass is subscribed to it.
class ConversationChannel < ActionCable::Channel::Base
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
      return false unless current_guest_session

      ActsAsTenant.with_tenant(current_guest_session.hotel) do
        current_guest_session.conversations.any? do |conversation|
          # self.class.send(...): #stream_name_from is a private method
          # from Turbo::Streams::StreamName, extended onto this class the
          # same way Turbo::StreamsChannel extends it onto itself — reusing
          # the exact algorithm that produced the client's stream name in
          # the first place, rather than a second hand-written decoding of
          # it, guarantees this stays correct if that algorithm ever
          # changes.
          self.class.send(:stream_name_from, conversation) == stream_name
        end
      end
    end
end
