require "application_system_test_case"

# The test that proves the slice, and the demo it describes: a guest sends
# a message on their phone, a receptionist sees it appear without touching
# anything, replies, and the guest sees the reply appear. Two real browser
# sessions, both live, neither reloaded by the test.
#
# Worth the setup cost precisely because nothing smaller proves it. The
# controller tests prove a reply is persisted and the channel tests prove
# who may subscribe; only this proves that the broadcast, the channel, the
# stream name, the morph, and both views actually line up end to end — the
# five places where a live-update feature really breaks.
#
# Two browsers are needed because the whole claim is about two people
# looking at the app at the same moment, each with their own cookie jar:
# the receptionist signed in as staff, the guest holding a guest cookie.
class GuestStaffLiveTest < ApplicationSystemTestCase
  # Turbo's page-refresh stream action debounces and coalesces refreshes,
  # and a morph re-render makes a full round trip, so the live assertions
  # below need more room than an ordinary same-page assertion. Still a
  # bounded wait, not a sleep: it returns the moment the text arrives.
  LIVE_WAIT = 15

  test "a guest message reaches reception live, and the reply reaches the guest live" do
    hotel = hotels(:stari_grad)
    conversation = ActsAsTenant.with_tenant(hotel) { Conversation.live_for(guest_sessions(:stari_guest)) }

    with_two_browsers do |guest, reception|
      sign_in_reception(reception)
      reception.visit staff_conversation_path(conversation)
      assert_cable_connected reception

      open_guest_chat(guest, hotel, "stari-grad-fixture-guest-token")

      guest.fill_in "message_body", with: "The shower in my room is cold."
      guest.find("#composer-send").click
      guest.within("#chat-messages") { guest.assert_text "The shower in my room is cold." }

      # The half that matters: no reload, no revisit, nothing driven on
      # this browser at all — the receptionist's page updated itself.
      reception.within("#transcript") do
        reception.assert_text "The shower in my room is cold.", wait: LIVE_WAIT
      end

      reception.fill_in "reply-body", with: "Maintenance is on their way now."
      reception.find("#reply-send").click
      reception.within("#transcript") { reception.assert_text "Maintenance is on their way now." }

      # ...and back the other way.
      guest.within("#chat-messages") do
        guest.assert_text "Maintenance is on their way now.", wait: LIVE_WAIT
      end
    end

    # What both browsers rendered is also what was actually written down.
    # (Capybara's own assertions raise rather than counting through
    # Minitest, so this is also what stops the run reporting this test as
    # having made no assertions at all.)
    ActsAsTenant.with_tenant(hotel) do
      assert conversation.messages.guest_visible.exists?(body: "The shower in my room is cold.")
      assert conversation.messages.guest_visible.exists?(body: "Maintenance is on their way now.")
    end
  end

  # The same live path, for the message that must NOT travel it. A note
  # written while the guest is sitting on their chat with a live cable is
  # the exact circumstance in which a leak would be invisible to everyone
  # until the guest mentioned it.
  test "an internal note written live never appears on the guest's open chat" do
    hotel = hotels(:stari_grad)
    conversation = ActsAsTenant.with_tenant(hotel) { Conversation.live_for(guest_sessions(:stari_guest)) }

    with_two_browsers do |guest, reception|
      open_guest_chat(guest, hotel, "stari-grad-fixture-guest-token")

      sign_in_reception(reception)
      reception.visit staff_conversation_path(conversation)
      reception.fill_in "note-body", with: "Do not comp this one, they already got a discount."
      reception.find("#note-save").click
      reception.within("#transcript") { reception.assert_text "Do not comp this one" }

      # A guest-visible reply sent afterwards is what makes this able to
      # fail: waiting for it proves the guest's live channel really was
      # delivering during the window the note was written, so "the note
      # never showed up" means it was filtered rather than that nothing
      # was arriving at all.
      ActsAsTenant.with_tenant(hotel) do
        conversation.post_staff_message!(user: users(:stari_staff), body: "Someone will be up shortly.")
      end

      guest.within("#chat-messages") do
        guest.assert_text "Someone will be up shortly.", wait: LIVE_WAIT
      end
      guest.assert_no_text "Do not comp this one"
    end

    ActsAsTenant.with_tenant(hotel) do
      note = conversation.messages.find_by!(body: "Do not comp this one, they already got a discount.")
      assert note.internal?, "the note was saved guest-visible — the browser assertion above only proves it did not arrive live"
      assert conversation.messages.guest_visible.exists?(body: "Someone will be up shortly.")
    end
  end

  private
    # Explicit Capybara::Session objects rather than Capybara.using_session:
    # a named session lives in Capybara's own pool and is reused by the
    # next test, but this suite's harness quits the browser after every
    # test (ApplicationSystemTestCase — deliberate, do not remove), and a
    # pooled session whose driver has been quit comes back to the next test
    # pointing at a chromedriver that is gone. Sessions created here are
    # owned by the test that made them and quit with it, so nothing
    # survives into the next test in either direction.
    def with_two_browsers
      guest = Capybara::Session.new(Capybara.current_driver, Capybara.app)
      reception = Capybara::Session.new(Capybara.current_driver, Capybara.app)

      yield guest, reception
    ensure
      [ guest, reception ].compact.each do |session|
        session.driver.quit if session.driver.respond_to?(:quit)
      rescue StandardError
        nil
      end
    end

    def sign_in_reception(session)
      session.visit root_url
      session.fill_in "email_address", with: users(:stari_staff).email_address
      session.fill_in "password", with: "password123"
      session.click_on "Sign in"
      # Assert on the destination, not the click (engineering rule 4):
      # click_on returns when the click is dispatched, not when the next
      # page has loaded, and racing that once left a session cookie unset.
      session.assert_text "Signed in as #{users(:stari_staff).name}"
    end

    def open_guest_chat(session, hotel, raw_token)
      # A cookie can only be set for a domain the browser has already
      # loaded, so this first visit exists purely to establish it before
      # injecting the signed cookie a real sign-up would have set via
      # Set-Cookie (same technique as test/system/guest_chat_test.rb).
      session.visit hotel_landing_path(hotel.slug)
      session.driver.browser.manage.add_cookie(
        name: "hospello_guest", value: guest_signed_cookie_value(raw_token), path: "/"
      )
      session.visit guest_chat_path
      assert_cable_connected session
    end

    # visible: :all — <turbo-cable-stream-source> is an empty custom
    # element with no box, so Capybara's default visibility filter never
    # matches it however connected it is.
    def assert_cable_connected(session)
      session.assert_selector "turbo-cable-stream-source[connected]", visible: :all, wait: LIVE_WAIT
    end

    def guest_signed_cookie_value(raw_token)
      jar = ActionDispatch::TestRequest.create.cookie_jar
      jar.signed[:hospello_guest] = raw_token
      jar[:hospello_guest]
    end
end
