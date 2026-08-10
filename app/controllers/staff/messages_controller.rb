module Staff
  # The reply composer's other half. Two kinds of message come through
  # here — a reply the guest will read, and an internal note the guest must
  # never see — and which one is being written is decided by an explicit
  # parameter, checked against an allow-list, rather than by anything
  # inferred from the form. Getting that wrong leaks staff commentary to a
  # guest, so it is worth being heavy-handed: an unrecognised value is
  # treated as a *reply*, the one interpretation that cannot leak anything.
  class MessagesController < BaseController
    REPLY = "reply".freeze
    INTERNAL_NOTE = "internal_note".freeze

    before_action :set_conversation

    def create
      body = message_params[:body].to_s

      if internal_note?
        authorize @conversation, :note?
        @conversation.post_internal_note!(user: Current.user, body: body)
        redirect_to staff_conversation_path(@conversation), notice: "Internal note saved. The guest cannot see it."
      else
        authorize @conversation, :reply?
        @conversation.post_staff_message!(user: Current.user, body: body)
        redirect_to staff_conversation_path(@conversation)
      end
    rescue ActiveRecord::RecordInvalid => invalid
      redirect_to staff_conversation_path(@conversation), alert: invalid.record.errors.full_messages.to_sentence
    rescue Conversation::SupersededConversation
      # The guest moved on to a newer conversation while this one sat
      # settled, so the reply was rolled back rather than left where
      # nobody would read it (see Conversation#post_staff_message!). Point
      # at the conversation the guest is actually in instead of reporting
      # a failure with no way forward — no dead ends applies to staff too.
      redirect_to superseding_conversation_path,
        alert: "This conversation was closed and the guest has since started a new one — your reply was not sent. " \
               "Continue in their current conversation."
    end

    private
      def set_conversation
        @conversation = Current.hotel.conversations.find(params[:conversation_id])
      end

      # Anything that is not exactly INTERNAL_NOTE is a reply. Stated this
      # way round on purpose: a typo, a stale form, or a crafted request
      # can only ever make a message *more* visible than intended, never
      # less.
      def internal_note?
        params[:kind] == INTERNAL_NOTE
      end

      def message_params
        params.require(:message).permit(:body)
      end

      def superseding_conversation_path
        live = Current.hotel.conversations.live.find_by(guest_session_id: @conversation.guest_session_id)
        live ? staff_conversation_path(live) : staff_conversations_path
      end
  end
end
