require "application_system_test_case"

# Short, single-purpose tests with preconditions set up directly in Ruby —
# per this suite's house rule (see test/system/guest_chat_test.rb and the
# engineering rules on the known Chrome click-delivery flake). Only the
# behaviour actually under test is driven through the browser.
class ReceptionInboxTest < ApplicationSystemTestCase
  test "a receptionist opens a waiting conversation and replies to the guest" do
    conversation = ActsAsTenant.with_tenant(hotels(:stari_grad)) do
      Conversation.live_for(guest_sessions(:stari_guest)).tap do |c|
        c.post_guest_message!(body: "Could I get a late checkout?", client_message_id: SecureRandom.uuid)
      end
    end

    sign_in_as_reception
    click_on "Inbox"
    assert_text "Could I get a late checkout?"

    find("##{dom_id(conversation)} a").click
    assert_text guest_sessions(:stari_guest).guest_name

    fill_in "reply-body", with: "Of course — 2pm is fine."
    find("#reply-send").click

    within "#transcript" do
      assert_text "Of course — 2pm is fine."
    end
    assert ActsAsTenant.with_tenant(hotels(:stari_grad)) {
      conversation.messages.guest_visible.exists?(body: "Of course — 2pm is fine.")
    }
  end

  # The boundary worth being heavy-handed about: an internal note has to
  # land in the staff transcript wearing its warning, and it must not reach
  # the guest's own chat. Both halves are asserted in one test on purpose —
  # separately, either half could pass while the note went to the wrong
  # place entirely.
  test "an internal note is labelled in the staff transcript and never reaches the guest's chat" do
    conversation = ActsAsTenant.with_tenant(hotels(:stari_grad)) do
      Conversation.live_for(guest_sessions(:stari_guest))
    end

    sign_in_as_reception
    visit staff_conversation_path(conversation)

    fill_in "note-body", with: "Guest has asked three times — check with housekeeping first."
    find("#note-save").click

    within "#transcript" do
      assert_text "Internal note — the guest cannot see this"
      assert_text "Guest has asked three times"
    end

    visit_guest_chat
    assert_selector "#chat-messages"
    assert_no_text "Guest has asked three times"
  end

  test "the needs-attention filter hides conversations that are not waiting on anyone" do
    waiting, quiet = ActsAsTenant.with_tenant(hotels(:stari_grad)) do
      hotels(:stari_grad).conversations.destroy_all
      unread = Conversation.live_for(new_guest_session("Waiting Guest"))
      unread.update!(staff_unread_count: 1)
      settled = Conversation.live_for(new_guest_session("Quiet Guest"))
      settled.update!(staff_unread_count: 0)
      [ unread, settled ]
    end

    sign_in_as_reception
    visit staff_conversations_path
    assert_selector "##{dom_id(quiet)}"

    find("#filter-needs_attention").click

    assert_selector "##{dom_id(waiting)}"
    assert_no_selector "##{dom_id(quiet)}"
  end

  test "searching by room number narrows the list to that guest" do
    match, other = ActsAsTenant.with_tenant(hotels(:stari_grad)) do
      hotels(:stari_grad).conversations.destroy_all
      wanted = Conversation.live_for(new_guest_session("Room Guest", room: rooms(:stari_302)))
      unwanted = Conversation.live_for(new_guest_session("Other Guest"))
      [ wanted, unwanted ]
    end

    sign_in_as_reception
    visit staff_conversations_path

    fill_in "q", with: rooms(:stari_302).number
    click_on "Search"

    assert_selector "##{dom_id(match)}"
    assert_no_selector "##{dom_id(other)}"
  end

  test "taking over from the assistant records it in the transcript" do
    conversation = ActsAsTenant.with_tenant(hotels(:stari_grad)) do
      Conversation.live_for(guest_sessions(:stari_guest))
    end

    sign_in_as_reception
    visit staff_conversation_path(conversation)

    find("#ai-mode-toggle").click

    assert_text "Reception is handling this conversation"
    within "#transcript" do
      assert_text "Reception took over the conversation."
    end
    assert ActsAsTenant.with_tenant(hotels(:stari_grad)) { conversation.reload.paused? }
  end

  private
    def sign_in_as_reception
      visit root_url
      fill_in "email_address", with: users(:stari_staff).email_address
      fill_in "password", with: "password123"
      click_on "Sign in"
      # Assert on the destination, not the click: click_on returns when the
      # click is dispatched, not when the next page has loaded (engineering
      # rule 4 — a race here once left the session cookie unset and
      # surfaced much later as a missing form field).
      assert_text "Signed in as #{users(:stari_staff).name}"
    end

    # Signs in as the fixture guest in the same browser, replacing the
    # staff session cookie's relevance for the guest routes — the guest
    # namespace reads only the hospello_guest cookie, so both can coexist.
    def visit_guest_chat
      visit hotel_landing_path(hotels(:stari_grad).slug)
      page.driver.browser.manage.add_cookie(
        name: "hospello_guest", value: guest_signed_cookie_value("stari-grad-fixture-guest-token"), path: "/"
      )
      visit guest_chat_path
    end

    def guest_signed_cookie_value(raw_token)
      jar = ActionDispatch::TestRequest.create.cookie_jar
      jar.signed[:hospello_guest] = raw_token
      jar[:hospello_guest]
    end

    def new_guest_session(name, room: nil)
      hotels(:stari_grad).guest_sessions.create!(
        guest_name: name, room: room, locale: "en", privacy_accepted_at: Time.current,
        expires_at: 7.days.from_now, token_digest: GuestSession.digest(SecureRandom.hex(16))
      )
    end
end
