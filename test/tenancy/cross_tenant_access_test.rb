require "test_helper"
# ActionCable::Channel::ConnectionStub/ChannelStub (used below to exercise
# ConversationChannel directly, without pulling in the rest of
# ActionCable::Channel::TestCase for a single test) live in this file,
# which nothing else in this test's own inheritance chain
# (ActionDispatch::IntegrationTest) requires on its own.
require "action_cable/channel/test_case"

# Every tenant-scoped staff resource must be invisible — 404, not 403 — when
# hotel A's admin requests it by hotel B's record id. A 403 would confirm the
# record exists (wrong hotel, but real); only a 404 proves it is genuinely
# out of reach. Extend this file as later slices add more tenant-scoped
# staff resources (Staff::BaseController's `Current.hotel.<assoc>.find` scoping
# is what actually produces the 404 — ActiveRecord::RecordNotFound on a
# foreign id — not a Pundit policy, which is never even reached).
class CrossTenantAccessTest < ActionDispatch::IntegrationTest
  test "hotel A staff cannot read or mutate hotel B's rooms" do
    vrelo_room = with_tenant(hotels(:vrelo)) { hotels(:vrelo).rooms.create!(number: "B-1") }
    sign_in users(:stari_admin)

    get edit_staff_room_path(vrelo_room)
    assert_response :not_found

    patch staff_room_path(vrelo_room), params: { room: { number: "HACKED" } }
    assert_response :not_found
    assert_equal "B-1", vrelo_room.reload.number

    delete staff_room_path(vrelo_room)
    assert_response :not_found
    assert_equal "B-1", vrelo_room.reload.number
  end

  test "hotel A staff cannot read or mutate hotel B's departments" do
    vrelo_department = with_tenant(hotels(:vrelo)) { hotels(:vrelo).departments.create!(name: "Vrelo Only Dept") }
    sign_in users(:stari_admin)

    get edit_staff_department_path(vrelo_department)
    assert_response :not_found

    patch staff_department_path(vrelo_department), params: { department: { name: "HACKED" } }
    assert_response :not_found
    assert_equal "Vrelo Only Dept", vrelo_department.reload.name

    delete staff_department_path(vrelo_department)
    assert_response :not_found
    assert_equal "Vrelo Only Dept", vrelo_department.reload.name
  end

  test "hotel A staff cannot read or mutate hotel B's request categories" do
    vrelo_category = with_tenant(hotels(:vrelo)) { hotels(:vrelo).request_categories.create!(key: "vrelo_only", name: "Vrelo Only Category") }
    sign_in users(:stari_admin)

    get edit_staff_request_category_path(vrelo_category)
    assert_response :not_found

    patch staff_request_category_path(vrelo_category), params: { request_category: { name: "HACKED" } }
    assert_response :not_found
    assert_equal "Vrelo Only Category", vrelo_category.reload.name

    delete staff_request_category_path(vrelo_category)
    assert_response :not_found
    assert_equal "Vrelo Only Category", vrelo_category.reload.name
  end

  # Staff::UsersController scopes through Current.hotel.users.find, exactly
  # like the resources above — User isn't TenantScoped (it's exempt from
  # acts_as_tenant so platform admins can have no hotel), so this 404 comes
  # entirely from the association scoping, not from acts_as_tenant at all.
  test "hotel A staff cannot read or mutate hotel B's users" do
    vrelo_user = users(:vrelo_staff)
    sign_in users(:stari_admin)

    get edit_staff_user_path(vrelo_user)
    assert_response :not_found

    patch staff_user_path(vrelo_user), params: { user: { active: false } }
    assert_response :not_found
    assert vrelo_user.reload.active?
  end

  # The knowledge base (Slice 3 Task 1). This one matters twice over: it is
  # a tenant boundary like any other, and it is also the corpus the
  # concierge answers from — so an entry leaking across hotels would not
  # just be visible on a screen, it would end up in another hotel's prompt.
  test "hotel A staff cannot read, edit, publish or delete hotel B's knowledge base entry" do
    vrelo_entry = with_tenant(hotels(:vrelo)) do
      hotels(:vrelo).kb_entries.create!(title: "Vrelo Only Entry", content: "Vrelo-only secret content.")
    end
    sign_in users(:stari_admin)

    get edit_staff_kb_entry_path(vrelo_entry)
    assert_response :not_found

    patch staff_kb_entry_path(vrelo_entry), params: { kb_entry: { content: "HACKED" } }
    assert_response :not_found

    patch publish_staff_kb_entry_path(vrelo_entry), params: { published: "true" }
    assert_response :not_found

    delete staff_kb_entry_path(vrelo_entry)
    assert_response :not_found

    with_tenant(hotels(:vrelo)) do
      vrelo_entry.reload
      assert_equal "Vrelo-only secret content.", vrelo_entry.content
      assert_not vrelo_entry.published?, "hotel A must not be able to put hotel B's text in front of guests"
    end
  end

  test "the knowledge base list shows only the signed-in staff member's own hotel's entries" do
    with_tenant(hotels(:vrelo)) do
      hotels(:vrelo).kb_entries.create!(title: "Vrelo Only Entry", content: "Vrelo-only secret content.")
    end
    with_tenant(hotels(:stari_grad)) do
      hotels(:stari_grad).kb_entries.create!(title: "Stari Only Entry", content: "Stari-only content.")
    end
    sign_in users(:stari_admin)

    get staff_kb_entries_path

    assert_response :success
    assert_match "Stari Only Entry", response.body
    assert_no_match "Vrelo Only Entry", response.body
    assert_no_match "Vrelo-only secret content.", response.body
  end

  # The reception inbox (Slice 2 Task 3). A conversation carries the guest's
  # name, room, and everything they have said — so hotel B's conversation
  # must be invisible to hotel A's staff on every one of its routes, not
  # only the obvious read. Each verb is checked separately because they
  # reach the record by three different code paths (#show, the nested
  # messages controller, and the two member actions), and a guard on one is
  # worth nothing to the other two.
  test "hotel A staff cannot read, reply to, or act on hotel B's conversation" do
    vrelo_conversation = conversations(:vrelo_conversation)
    messages_before = with_tenant(hotels(:vrelo)) { vrelo_conversation.messages.count }
    sign_in users(:stari_admin)

    get staff_conversation_path(vrelo_conversation)
    assert_response :not_found

    post staff_conversation_messages_path(vrelo_conversation),
      params: { kind: "reply", message: { body: "cross-tenant reply attempt" } }
    assert_response :not_found

    post staff_conversation_messages_path(vrelo_conversation),
      params: { kind: "internal_note", message: { body: "cross-tenant note attempt" } }
    assert_response :not_found

    patch ai_mode_staff_conversation_path(vrelo_conversation)
    assert_response :not_found

    patch resolve_staff_conversation_path(vrelo_conversation)
    assert_response :not_found

    with_tenant(hotels(:vrelo)) do
      assert_equal messages_before, vrelo_conversation.reload.messages.count,
        "hotel B's conversation must not have received anything from hotel A's staff"
      assert vrelo_conversation.active?, "hotel B's conversation must not have been resolved by hotel A's staff"
      assert vrelo_conversation.auto?, "hotel B's conversation's AI mode must not be flippable by hotel A's staff"
    end
  end

  # The inbox list is the other shape of the same boundary: #show 404s on a
  # named id, but the list names no ids at all, so nothing about that 404
  # says the list itself is scoped. This checks the rendered page.
  test "the inbox lists only the signed-in staff member's own hotel's conversations" do
    sign_in users(:stari_admin)

    get staff_conversations_path

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(conversations(:stari_conversation))}"
    assert_select "##{ActionView::RecordIdentifier.dom_id(conversations(:vrelo_conversation))}", count: 0
    # Guest names are what a conversation row actually leaks if the scoping
    # is wrong, so they are asserted directly rather than only via dom ids.
    assert_select "#conversation-list", text: /#{Regexp.escape(guest_sessions(:stari_guest).guest_name)}/
    assert_select "#conversation-list", text: /#{Regexp.escape(guest_sessions(:vrelo_guest).guest_name)}/, count: 0
  end

  # Searching is a second, independent way into the list — it builds a
  # different query (a left join across guest_sessions and rooms), so
  # "the list is scoped" does not by itself mean "the search is scoped".
  #
  # Asserted against the rendered rows, not the whole page: the page echoes
  # the query back in the search field and in "No conversations match …",
  # so a blanket assert_no_match on the guest's name fails on the search
  # box rather than on any leak. The row count is what actually
  # distinguishes "found nothing" from "found hotel B's guest".
  test "inbox search can never surface another hotel's guest" do
    sign_in users(:stari_admin)

    get staff_conversations_path(q: guest_sessions(:vrelo_guest).guest_name)

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(conversations(:vrelo_conversation))}", count: 0
    assert_select "#conversation-list li", count: 0
    assert_select "#inbox-empty"
  end

  # ...and the same search run by that guest's *own* hotel does find them,
  # so the test above cannot be passing because the search is simply broken.
  test "inbox search does find a guest at the searcher's own hotel" do
    sign_in users(:vrelo_admin)

    get staff_conversations_path(q: guest_sessions(:vrelo_guest).guest_name)

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(conversations(:vrelo_conversation))}"
  end

  # The staff-side live transport, mirroring the guest-side ConversationChannel
  # test below: a validly-signed name for hotel B's inbox stream (Turbo's
  # signing proves only that it wasn't tampered with) must be refused for a
  # hotel A staff member's connection.
  test "hotel A staff can never subscribe to hotel B's inbox stream over ActionCable" do
    signed_name = Turbo::StreamsChannel.signed_stream_name([ hotels(:vrelo), :inbox ])

    connection = ActionCable::Channel::ConnectionStub.new(current_user: users(:stari_staff), current_guest_session: nil)
    subscription = HotelInboxChannel.new(connection, "test_stub", { "signed_stream_name" => signed_name }.with_indifferent_access)
    subscription.singleton_class.include(ActionCable::Channel::ChannelStub)
    subscription.subscribe_to_channel

    assert subscription.rejected?
  end

  # Guest sessions (Slice 2 Task 1) are the other side of this app's tenancy
  # boundary: there is no id, slug, or any other hotel-identifying value
  # anywhere in the guest namespace's own routes — Guest::BaseController
  # resolves Current.hotel from the guest's signed cookie alone (see that
  # controller's comment for why). A cookie issued by hotel A must never
  # resolve to hotel B's data, the guest-side analogue of the staff
  # 404-not-403 tests above.
  test "a guest cookie issued by hotel A always resolves to hotel A's data, never hotel B's" do
    sign_in_guest("stari-grad-fixture-guest-token")

    get guest_chat_path

    assert_response :success
    assert_select "#chat-greeting", text: /#{Regexp.escape(guest_sessions(:stari_guest).guest_name)}/
    assert_select "#chat-greeting", text: /#{Regexp.escape(guest_sessions(:vrelo_guest).guest_name)}/, count: 0
    # #hotel-name renders Current.hotel.name specifically (not
    # @guest_session.hotel.name) — this pins that
    # Guest::BaseController#scope_to_guest_hotel set the tenant correctly,
    # not just that the right GuestSession row was found.
    assert_select "#hotel-name", text: hotels(:stari_grad).name
  end

  # The other direction, proving the test above isn't passing just because
  # this controller always happens to resolve hotel A — a different guest's
  # cookie must resolve to *its own* hotel's data instead.
  test "a guest cookie issued by hotel B always resolves to hotel B's data, never hotel A's" do
    sign_in_guest("vrelo-bosne-fixture-guest-token")

    get guest_chat_path

    assert_response :success
    assert_select "#chat-greeting", text: /#{Regexp.escape(guest_sessions(:vrelo_guest).guest_name)}/
    assert_select "#chat-greeting", text: /#{Regexp.escape(guest_sessions(:stari_guest).guest_name)}/, count: 0
    assert_select "#hotel-name", text: hotels(:vrelo).name
  end

  # Even a request that actively tries to hint at a different hotel (a
  # crafted query param no legitimate client sends) must be ignored —
  # Guest::BaseController never reads a hotel from params, only from the
  # cookie's resolved session.
  test "a crafted hotel-identifying query param on a guest route is ignored — the hotel always comes from the cookie" do
    sign_in_guest("stari-grad-fixture-guest-token")

    get guest_chat_path(hotel_slug: hotels(:vrelo).slug, hotel_id: hotels(:vrelo).id)

    assert_response :success
    assert_select "#chat-greeting", text: /#{Regexp.escape(guest_sessions(:stari_guest).guest_name)}/
  end

  # Slice 2's own tenant boundary: a guest session must never post into,
  # read, or subscribe to another hotel's conversation. Guest::MessagesController
  # never reads a conversation id from params at all — it always resolves
  # Conversation.live_for(Current.guest_session) — so this proves that
  # holds even against a request that actively tries to name a different
  # conversation, not just that a legitimate request happens to land
  # correctly.
  test "a guest session for hotel A can never post into hotel B's conversation, even via a crafted conversation_id param" do
    sign_in_guest("stari-grad-fixture-guest-token")
    vrelo_conversation = conversations(:vrelo_conversation)
    vrelo_message_count_before = with_tenant(hotels(:vrelo)) { vrelo_conversation.messages.count }

    post guest_messages_path,
      params: { message: { body: "cross-tenant post attempt", client_message_id: SecureRandom.uuid, conversation_id: vrelo_conversation.id } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal vrelo_message_count_before, with_tenant(hotels(:vrelo)) { vrelo_conversation.reload.messages.count },
      "hotel B's conversation must not receive a message from hotel A's guest"

    stari_conversation = with_tenant(hotels(:stari_grad)) { Conversation.live_for(guest_sessions(:stari_guest)) }
    assert with_tenant(hotels(:stari_grad)) { stari_conversation.messages.exists?(body: "cross-tenant post attempt") },
      "the message must land in hotel A's own conversation instead"
  end

  # The resync endpoint resolves the same way — Conversation.live_for(Current.guest_session)
  # — so a hotel A guest's ?after= request can only ever return hotel A's
  # own messages, never hotel B's, regardless of what "after" id is given.
  test "a guest session for hotel A can never read hotel B's messages via the resync endpoint" do
    with_tenant(hotels(:vrelo)) do
      Conversation.live_for(guest_sessions(:vrelo_guest))
        .post_guest_message!(body: "hotel-b-only-secret-message", client_message_id: SecureRandom.uuid)
    end

    sign_in_guest("stari-grad-fixture-guest-token")
    get guest_messages_path, params: { after: 0 }, headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_no_match "hotel-b-only-secret-message", response.body
  end

  # The live-update transport: even a validly-signed stream name for
  # hotel B's conversation (Turbo's signing proves it wasn't tampered
  # with — it says nothing about who is allowed to hold it) must be
  # refused for a hotel A guest's connection. See
  # test/channels/conversation_channel_test.rb for the fuller suite this
  # boundary gets exercised against; this pins the same guarantee here
  # per this app's convention of keeping every tenant-boundary proof
  # discoverable from this one file.
  test "a guest session for hotel A can never subscribe to hotel B's conversation over ActionCable" do
    vrelo_conversation = with_tenant(hotels(:vrelo)) { Conversation.live_for(guest_sessions(:vrelo_guest)) }
    signed_name = Turbo::StreamsChannel.signed_stream_name(vrelo_conversation)

    connection = ActionCable::Channel::ConnectionStub.new(current_user: nil, current_guest_session: guest_sessions(:stari_guest))
    subscription = ConversationChannel.new(connection, "test_stub", { "signed_stream_name" => signed_name }.with_indifferent_access)
    subscription.singleton_class.include(ActionCable::Channel::ChannelStub)
    subscription.subscribe_to_channel

    assert subscription.rejected?
  end
end
