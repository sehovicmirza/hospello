# Slice 2 Task 1 owns just enough of this controller to prove the guest
# session/cookie/tenant machinery works end to end: a real page, rendered
# inside the guest layout (so <html dir="rtl"> and the guest's chosen
# locale are genuinely exercised — see test/system/guest_entry_test.rb),
# that greets the guest by name and room.
#
# Task 2 owns this controller from here: it replaces #show with the actual
# chat UI and adds the message-sending action the guest_messages/ip
# Rack::Attack throttle (config/initializers/rack_attack.rb) is really for.
# Nothing here is meant to survive that task unchanged.
module Guest
  class ChatsController < BaseController
    def show
      @guest_session = Current.guest_session
    end
  end
end
