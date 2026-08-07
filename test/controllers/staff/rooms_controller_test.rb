require "test_helper"

# `Room.unscoped.count` (not `Room.count`) inside assert_(no_)difference
# blocks throughout this file: a bare Room.count has no ambient tenant at
# the point the block is evaluated and would raise
# ActsAsTenant::Errors::NoTenantSet under require_tenant = true.
# `.unscoped` bypasses acts_as_tenant's default_scope entirely (a different,
# safe mechanism from ActsAsTenant.without_tenant — no grep-test relevance,
# and fine to use freely in tests) to get a true cross-tenant row count.
class Staff::RoomsControllerTest < ActionDispatch::IntegrationTest
  test "a hotel admin sees the hotel's own rooms, not another hotel's" do
    sign_in users(:stari_admin)

    get staff_rooms_path

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(rooms(:stari_301))} td", text: "301"
    # vrelo's rooms must never leak into stari_grad's list, scoped to a row
    # (not a page-wide substring — "401" could otherwise coincidentally
    # match something in a Tailwind class or elsewhere in the markup).
    assert_select "##{ActionView::RecordIdentifier.dom_id(rooms(:vrelo_401))}", count: 0
  end

  test "plain staff can view the rooms list" do
    sign_in users(:stari_staff)

    get staff_rooms_path

    assert_response :success
  end

  # The staff layout's nav previously rendered "Rooms" as an inert
  # `path: nil` placeholder (see staff_helper.rb); this pins that the swap
  # to a real path actually happened, for both roles that can read rooms.
  test "the staff nav offers a working Rooms link to a hotel admin" do
    sign_in users(:stari_admin)

    get staff_root_path

    assert_response :success
    assert_select "nav a[href=?]", staff_rooms_path, text: "Rooms", count: 1
  end

  test "the staff nav offers a working Rooms link to plain staff too (read-only, not admin-only)" do
    sign_in users(:stari_staff)

    get staff_root_path

    assert_response :success
    assert_select "nav a[href=?]", staff_rooms_path, text: "Rooms", count: 1
  end

  test "plain staff sees no add-room form" do
    sign_in users(:stari_staff)

    get staff_rooms_path

    assert_response :success
    assert_select "form[action=?]", staff_rooms_path, count: 0
  end

  test "a hotel admin can add a single room" do
    sign_in users(:stari_admin)

    assert_difference -> { Room.unscoped.count }, 1 do
      post staff_rooms_path, params: { room: { number: " 204 " } }
    end

    assert_redirected_to staff_rooms_path
    room = with_tenant(hotels(:stari_grad)) { hotels(:stari_grad).rooms.find_by!(number: "204") }
    assert room.active?
  end

  test "adding a duplicate room number re-renders with an error instead of a 500" do
    sign_in users(:stari_admin)

    assert_no_difference -> { Room.unscoped.count } do
      post staff_rooms_path, params: { room: { number: rooms(:stari_301).number } }
    end

    assert_response :unprocessable_content
    assert_select "li", text: "Number has already been taken"
  end

  test "plain staff cannot add a room" do
    sign_in users(:stari_staff)

    assert_no_difference -> { Room.unscoped.count } do
      post staff_rooms_path, params: { room: { number: "555" } }
    end

    assert_response :forbidden
  end

  test "a hotel admin can bulk-add rooms and gets a created/skipped summary" do
    sign_in users(:stari_admin)

    assert_difference -> { Room.unscoped.count }, 2 do
      post bulk_create_staff_rooms_path, params: { bulk: { numbers: "601-602, #{rooms(:stari_301).number}" } }
    end

    assert_redirected_to staff_rooms_path
    follow_redirect!
    assert_match "2 rooms added, 1 skipped as duplicate.", response.body

    with_tenant(hotels(:stari_grad)) do
      assert hotels(:stari_grad).rooms.exists?(number: "601")
      assert hotels(:stari_grad).rooms.exists?(number: "602")
    end
  end

  test "bulk-add refuses an absurd range instead of creating thousands of rooms" do
    sign_in users(:stari_admin)

    assert_no_difference -> { Room.unscoped.count } do
      post bulk_create_staff_rooms_path, params: { bulk: { numbers: "1-99999" } }
    end

    assert_redirected_to staff_rooms_path
    follow_redirect!
    assert_match "500-room", response.body
  end

  test "plain staff cannot bulk-add rooms" do
    sign_in users(:stari_staff)

    assert_no_difference -> { Room.unscoped.count } do
      post bulk_create_staff_rooms_path, params: { bulk: { numbers: "701,702" } }
    end

    assert_response :forbidden
  end

  test "a hotel admin can rename and deactivate a room" do
    sign_in users(:stari_admin)
    room = rooms(:stari_301)

    patch staff_room_path(room), params: { room: { number: "301A", active: false } }

    assert_redirected_to staff_rooms_path
    room.reload
    assert_equal "301A", room.number
    assert_not room.active?
  end

  test "plain staff cannot update a room" do
    sign_in users(:stari_staff)
    room = rooms(:stari_301)
    original_number = room.number

    patch staff_room_path(room), params: { room: { number: "HACKED" } }

    assert_response :forbidden
    assert_equal original_number, room.reload.number
  end

  test "a hotel admin can delete an unreferenced room" do
    sign_in users(:stari_admin)
    room = with_tenant(hotels(:stari_grad)) { hotels(:stari_grad).rooms.create!(number: "999") }

    assert_difference -> { Room.unscoped.count }, -1 do
      delete staff_room_path(room)
    end

    assert_redirected_to staff_rooms_path
  end

  test "plain staff cannot delete a room" do
    sign_in users(:stari_staff)
    room = rooms(:stari_301)

    assert_no_difference -> { Room.unscoped.count } do
      delete staff_room_path(room)
    end

    assert_response :forbidden
  end

  test "a signed-out user is redirected to sign-in for every rooms route" do
    room = rooms(:stari_301)

    staff_room_routes(room).each do |method, path|
      send(method, path)
      assert_redirected_to new_session_path, "expected a redirect for #{method.upcase} #{path}"
    end
  end

  test "a platform admin cannot reach any rooms route" do
    sign_in users(:platform)
    room = rooms(:stari_301)

    staff_room_routes(room).each do |method, path|
      send(method, path)
      assert_response :forbidden, "expected 403 for #{method.upcase} #{path}"
    end
  end

  private
    def staff_room_routes(room)
      [
        [ :get, staff_rooms_path ],
        [ :post, staff_rooms_path ],
        [ :post, bulk_create_staff_rooms_path ],
        [ :get, edit_staff_room_path(room) ],
        [ :patch, staff_room_path(room) ],
        [ :delete, staff_room_path(room) ]
      ]
    end
end
