require "test_helper"

# The reception inbox. Staff::BaseController (see that controller) sets the
# tenant from the signed-in user's own hotel, so cross-hotel isolation is
# proven in test/tenancy/cross_tenant_access_test.rb per this app's
# convention of keeping every tenant-boundary proof discoverable from that
# one file; these tests cover what this controller adds on top of it.
#
# Assertions are scoped to a specific element throughout (assert_select
# within a row, never assert_match against the whole page): a bare
# `assert_match "2", response.body` would pass on any Tailwind class name
# containing a 2, which is the single most common defect this codebase has
# produced.
class Staff::ConversationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @hotel = hotels(:stari_grad)
    @staff = users(:stari_staff)
  end

  test "the inbox lists this hotel's conversations and never another hotel's" do
    sign_in @staff

    get staff_conversations_path

    assert_response :success
    assert_select "##{dom_id(conversations(:stari_conversation))}"
    assert_select "##{dom_id(conversations(:vrelo_conversation))}", count: 0
  end

  test "the inbox sorts conversations needing attention above quieter, more recent ones" do
    stale_but_unread, recent_and_quiet = with_tenant(@hotel) do
      @hotel.conversations.destroy_all
      unread = Conversation.live_for(fresh_guest_session(name: "Unread Guest"))
      unread.update!(staff_unread_count: 1, last_message_at: 3.hours.ago)
      quiet = Conversation.live_for(fresh_guest_session(name: "Quiet Guest"))
      quiet.update!(staff_unread_count: 0, last_message_at: 1.minute.ago)
      [ unread, quiet ]
    end
    sign_in @staff

    get staff_conversations_path

    assert_response :success
    rendered_order = css_select("#conversation-list li").map { |row| row["id"] }
    assert_equal [ dom_id(stale_but_unread), dom_id(recent_and_quiet) ], rendered_order
  end

  test "the needs-attention filter hides conversations that are not waiting on anyone" do
    waiting, quiet = with_tenant(@hotel) do
      @hotel.conversations.destroy_all
      unread = Conversation.live_for(fresh_guest_session(name: "Waiting Guest"))
      unread.update!(staff_unread_count: 1)
      settled = Conversation.live_for(fresh_guest_session(name: "Quiet Guest"))
      settled.update!(staff_unread_count: 0)
      [ unread, settled ]
    end
    sign_in @staff

    get staff_conversations_path(filter: :needs_attention)

    assert_response :success
    assert_select "##{dom_id(waiting)}"
    assert_select "##{dom_id(quiet)}", count: 0
  end

  test "the resolved filter shows only settled conversations" do
    live, resolved = with_tenant(@hotel) do
      @hotel.conversations.destroy_all
      open_one = Conversation.live_for(fresh_guest_session(name: "Still Talking"))
      settled_one = Conversation.live_for(fresh_guest_session(name: "All Done"))
      settled_one.update!(status: :resolved)
      [ open_one, settled_one ]
    end
    sign_in @staff

    get staff_conversations_path(filter: :resolved)

    assert_response :success
    assert_select "##{dom_id(resolved)}"
    assert_select "##{dom_id(live)}", count: 0
  end

  # An unrecognised ?filter= must fall back to the full list rather than
  # reaching a scope lookup — a crafted value is otherwise a way to call an
  # arbitrary scope by name.
  test "an unknown filter falls back to the full list instead of erroring" do
    sign_in @staff

    get staff_conversations_path(filter: "destroy_all")

    assert_response :success
    assert_select "#filter-all[aria-current=?]", "page"
    assert_select "##{dom_id(conversations(:stari_conversation))}"
  end

  test "search finds a conversation by guest name" do
    match, other = with_tenant(@hotel) do
      @hotel.conversations.destroy_all
      wanted = Conversation.live_for(fresh_guest_session(name: "Ingrid Lindqvist"))
      unwanted = Conversation.live_for(fresh_guest_session(name: "Someone Else"))
      [ wanted, unwanted ]
    end
    sign_in @staff

    get staff_conversations_path(q: "lindqvist")

    assert_response :success
    assert_select "##{dom_id(match)}"
    assert_select "##{dom_id(other)}", count: 0
  end

  test "search finds a conversation by room number" do
    match, other = with_tenant(@hotel) do
      @hotel.conversations.destroy_all
      wanted = Conversation.live_for(fresh_guest_session(name: "In A Room", room: rooms(:stari_302)))
      unwanted = Conversation.live_for(fresh_guest_session(name: "No Room Guest"))
      [ wanted, unwanted ]
    end
    sign_in @staff

    get staff_conversations_path(q: rooms(:stari_302).number)

    assert_response :success
    assert_select "##{dom_id(match)}"
    assert_select "##{dom_id(other)}", count: 0
  end

  # The tab counts describe the queue, not the current search — a count
  # that shrank as a receptionist typed would read as work disappearing.
  test "the tab counts ignore the current search" do
    with_tenant(@hotel) do
      @hotel.conversations.destroy_all
      Conversation.live_for(fresh_guest_session(name: "Ingrid Lindqvist")).update!(staff_unread_count: 1)
      Conversation.live_for(fresh_guest_session(name: "Someone Else")).update!(staff_unread_count: 1)
    end
    sign_in @staff

    get staff_conversations_path(q: "lindqvist")

    assert_response :success
    assert_select "#conversation-list li", count: 1
    # @staff (stari_staff) reads the staff workspace in Bosnian — see
    # fixtures — so the "All" filter tab reads "Svi"
    # (staff.conversations.index.filters.all, config/locales/staff.bs.yml).
    assert_select "#filter-all", text: /Svi\s*2/
  end

  test "a row shows the guest name, room, channel and the UNVERIFIED badge" do
    conversation = with_tenant(@hotel) do
      @hotel.conversations.destroy_all
      Conversation.live_for(fresh_guest_session(name: "Ingrid Lindqvist", room: rooms(:stari_302)))
    end
    sign_in @staff

    get staff_conversations_path

    assert_response :success
    # @staff (stari_staff) reads the staff workspace in Bosnian — see
    # fixtures — so room/channel/identity-badge copy comes from
    # staff.common.room/channel/identity_badge (config/locales/staff.bs.yml).
    assert_select "##{dom_id(conversation)}" do
      assert_select "*", text: "Ingrid Lindqvist"
      assert_select "*", text: "Soba #{rooms(:stari_302).number}"
      assert_select "*", text: "Web razgovor"
      assert_select "*", text: "NEPROVJERENO"
    end
  end

  # Noticing is half of what this screen has to do, and it must never rest
  # on colour alone.
  test "a row needing attention is marked with words, not only a colour" do
    waiting = with_tenant(@hotel) do
      @hotel.conversations.destroy_all
      conversation = Conversation.live_for(fresh_guest_session(name: "Waiting Guest"))
      conversation.update!(staff_unread_count: 2)
      conversation
    end
    sign_in @staff

    get staff_conversations_path

    assert_response :success
    # @staff reads in Bosnian — see fixtures.
    # staff.conversations.conversation_row.needs_attention.
    assert_select "##{dom_id(waiting)}" do
      assert_select "*", text: "Zahtijeva pažnju"
    end
  end

  test "opening a conversation resets its unread count" do
    conversation = with_tenant(@hotel) do
      Conversation.live_for(guest_sessions(:stari_guest)).tap { |c| c.update!(staff_unread_count: 4) }
    end
    sign_in @staff

    get staff_conversation_path(conversation)

    assert_response :success
    assert_equal 0, with_tenant(@hotel) { conversation.reload.staff_unread_count }
  end

  test "the conversation view shows the whole transcript, internal notes included" do
    conversation = with_tenant(@hotel) do
      c = Conversation.live_for(guest_sessions(:stari_guest))
      c.post_guest_message!(body: "guest-said-this", client_message_id: SecureRandom.uuid)
      c.post_staff_message!(user: @staff, body: "staff-replied-this")
      c.post_internal_note!(user: @staff, body: "internally-noted-this")
      c
    end
    sign_in @staff

    get staff_conversation_path(conversation)

    assert_response :success
    assert_select "#transcript" do
      assert_select "*", text: /guest-said-this/
      assert_select "*", text: /staff-replied-this/
      assert_select "*", text: /internally-noted-this/
    end
  end

  # The boundary that stops staff commentary reaching a guest is drawn in
  # words, not only in styling — a receptionist skimming has to be told,
  # not shown a shade of purple.
  test "an internal note carries the literal warning that the guest cannot see it" do
    conversation, note = with_tenant(@hotel) do
      c = Conversation.live_for(guest_sessions(:stari_guest))
      [ c, c.post_internal_note!(user: @staff, body: "internally-noted-this") ]
    end
    sign_in @staff

    get staff_conversation_path(conversation)

    assert_response :success
    # @staff (stari_staff) reads the staff workspace in Bosnian — see
    # fixtures. This is staff.conversations.message.internal_note_banner
    # (config/locales/staff.bs.yml), pasted literally rather than looked
    # up so this test does not read the same source the view does — the
    # whole point of this test is that the literal warning sentence is
    # actually on the page.
    assert_select "##{dom_id(note)}" do
      assert_select "*", text: /Interna napomena — gost ovo ne može vidjeti/
    end
  end

  test "the AI toggle pauses and resumes, recording who did it" do
    conversation = with_tenant(@hotel) { Conversation.live_for(guest_sessions(:stari_guest)) }
    sign_in @staff

    patch ai_mode_staff_conversation_path(conversation)
    assert_redirected_to staff_conversation_path(conversation)
    assert with_tenant(@hotel) { conversation.reload.paused? }

    takeover = with_tenant(@hotel) { conversation.messages.last }
    assert takeover.system?
    assert takeover.internal?
    assert_equal @staff, takeover.sender_user

    patch ai_mode_staff_conversation_path(conversation)
    assert with_tenant(@hotel) { conversation.reload.auto? }
  end

  test "marking a conversation resolved settles it and moves it out of the live list" do
    conversation = with_tenant(@hotel) { Conversation.live_for(guest_sessions(:stari_guest)) }
    sign_in @staff

    patch resolve_staff_conversation_path(conversation)

    assert_redirected_to staff_conversations_path
    assert with_tenant(@hotel) { conversation.reload.resolved? }
  end

  # A receptionist is the primary user of this screen — plain staff, not
  # hotel_admin. A policy that reserved the inbox for managers would make
  # "a guest can always reach a human" depend on who is at the desk.
  test "a plain staff member may work the inbox, not only a hotel admin" do
    sign_in @staff
    conversation = with_tenant(@hotel) { Conversation.live_for(guest_sessions(:stari_guest)) }

    get staff_conversations_path
    assert_response :success

    get staff_conversation_path(conversation)
    assert_response :success
  end

  test "a deactivated staff member cannot reach the inbox" do
    @staff.update!(active: false)
    sign_in @staff

    get staff_conversations_path

    assert_response :forbidden
  end

  private
    def fresh_guest_session(name:, room: nil)
      @hotel.guest_sessions.create!(
        guest_name: name, room: room, locale: "en", privacy_accepted_at: Time.current,
        expires_at: 7.days.from_now, token_digest: GuestSession.digest(SecureRandom.hex(16))
      )
    end
end
