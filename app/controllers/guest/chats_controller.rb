# Guest::BaseController (inherited) does the session/locale/tenant work —
# see that controller. This is Task 2's real chat surface, replacing Task
# 1's deliberately thin placeholder wholesale (see that task's own comment,
# now gone from history but not forgotten).
module Guest
  class ChatsController < BaseController
    def show
      @guest_session = Current.guest_session
      @conversation = Conversation.live_for(@guest_session)
      # .guest_visible, never a bare `messages`: since Slice 2 Task 3 this
      # table also holds the reception inbox's internal notes, which the
      # guest must never see (Message#visibility). Every guest-facing read
      # of `messages` in this app carries this scope — see
      # Guest::MessagesController#index and Conversation#broadcast_new_message
      # for the other two.
      @messages = @conversation.messages.guest_visible.chronological.to_a
      # The summary card, if there is something waiting to be agreed to. A
      # guest who reloads mid-decision has to find it still there — the card
      # is the only place the confirmation actually happens for someone who
      # taps rather than types.
      @pending_draft = pending_draft
    end

    private
      def pending_draft
        draft = ServiceRequestDraft.live_for(@conversation)
        draft if draft&.status_awaiting_confirmation?
      end
  end
end
