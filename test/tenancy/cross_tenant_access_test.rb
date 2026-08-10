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
