# Guest::BaseController (inherited) does the session/locale/tenant work —
# see that controller. This is Task 2's real chat surface, replacing Task
# 1's deliberately thin placeholder wholesale (see that task's own comment,
# now gone from history but not forgotten).
module Guest
  class ChatsController < BaseController
    def show
      @guest_session = Current.guest_session
      @conversation = Conversation.live_for(@guest_session)
      @messages = @conversation.messages.chronological.to_a
    end
  end
end
