require "test_helper"

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
end
