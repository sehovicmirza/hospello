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
    # stari_admin reads the staff workspace in Bosnian — see fixtures.
    assert_select "nav a[href=?]", staff_rooms_path, text: "Sobe", count: 1
  end

  test "the staff nav offers a working Rooms link to plain staff too (read-only, not admin-only)" do
    sign_in users(:stari_staff)

    get staff_root_path

    assert_response :success
    # stari_staff reads the staff workspace in Bosnian too — see fixtures.
    assert_select "nav a[href=?]", staff_rooms_path, text: "Sobe", count: 1
  end

  test "plain staff sees no add-room form" do
    sign_in users(:stari_staff)

    get staff_rooms_path

    assert_response :success
    assert_select "form[action=?]", staff_rooms_path, count: 0
  end

  # Review round 1: this "count: 0 for staff" assertion had no positive
  # counterpart anywhere in the suite — changing `if policy(Room).create?`
  # to `if false` in the view would leave the whole suite green. Only a
  # test that the form actually renders for the role that should see it
  # can catch that.
  test "a hotel admin sees the add-room and bulk-add forms" do
    sign_in users(:stari_admin)

    get staff_rooms_path

    assert_response :success
    assert_select "form[action=?]", staff_rooms_path, count: 1
    assert_select "form[action=?]", bulk_create_staff_rooms_path, count: 1
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
    # stari_admin's locale is bs; rails-i18n supplies the Bosnian
    # ActiveRecord error vocabulary for "has already been taken".
    assert_select "li", text: "Number je već zauzet"
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
    # stari_admin reads the staff workspace in Bosnian — see fixtures.
    # staff.rooms.bulk_create (config/locales/staff.bs.yml): Bosnian takes
    # three forms, so count: 2 is "few" ("%{count} sobe dodane" — NOT the
    # "soba dodano" that English-shaped one/other pluralisation would give)
    # and count: 1 is "one" ("1 preskočena kao duplikat").
    assert_match "2 sobe dodane, 1 preskočena kao duplikat.", response.body

    with_tenant(hotels(:stari_grad)) do
      assert hotels(:stari_grad).rooms.exists?(number: "601")
      assert hotels(:stari_grad).rooms.exists?(number: "602")
    end
  end

  # The inverse count combination from the test above — "one" for created,
  # "few" for skipped, rather than the other way round — so between the two,
  # both of staff.rooms.bulk_create's independently pluralized phrases
  # (config/locales/staff.bs.yml) are exercised in both forms, not just one
  # each.
  test "the bulk-add summary correctly pluralizes the created and skipped counts independently" do
    sign_in users(:stari_admin)

    assert_difference -> { Room.unscoped.count }, 1 do
      post bulk_create_staff_rooms_path,
        params: { bulk: { numbers: "603, #{rooms(:stari_301).number}, #{rooms(:stari_302).number}" } }
    end

    follow_redirect!
    assert_match "1 soba dodana, 2 preskočene kao duplikati.", response.body
  end

  # Bosnian's third form, which English does not have and which the two tests
  # above cannot reach: counts of five and up take "other", not "few". Without
  # this, `few` and `other` could be swapped in the locale file and the suite
  # would stay green — the two tests above only ever ask for 1 and 2.
  test "the bulk-add summary uses Bosnian's third plural form for larger counts" do
    sign_in users(:stari_admin)

    assert_difference -> { Room.unscoped.count }, 5 do
      post bulk_create_staff_rooms_path, params: { bulk: { numbers: "701-705" } }
    end

    follow_redirect!
    assert_match "5 soba dodano", response.body
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

  # Review round 1: measured ~153s and ~200,000 queries against the
  # unbatched bulk_add loop for this exact shape (200 individually-legal
  # 500-room ranges) before Room::MAX_BULK_TOTAL existed. Reaching the
  # redirect at all — fast — is the point; nothing here should touch the
  # per-row loop.
  test "bulk-add refuses combined legal ranges that would still create too many rooms" do
    sign_in users(:stari_admin)
    text = (1..200).map { |i| "#{(i - 1) * 500 + 1}-#{i * 500}" }.join(",")

    assert_no_difference -> { Room.unscoped.count } do
      post bulk_create_staff_rooms_path, params: { bulk: { numbers: text } }
    end

    assert_redirected_to staff_rooms_path
    follow_redirect!
    assert_match "2000-room", response.body
  end

  # Review round 1: `params.dig(:bulk, :numbers)` raised a raw TypeError
  # (an unhandled 500) for a crafted request where `bulk` isn't a nested
  # hash at all.
  test "bulk-add does not crash when bulk is posted as a bare scalar instead of a nested hash" do
    sign_in users(:stari_admin)

    assert_no_difference -> { Room.unscoped.count } do
      post bulk_create_staff_rooms_path, params: { bulk: "x" }
    end

    assert_redirected_to staff_rooms_path
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

  # Probed directly: active: "" casts to nil (ActiveModel::Type::Boolean),
  # and rooms.active is null: false — unguarded, that reached Postgres as an
  # unrescued NotNullViolation (a 500) instead of a normal re-render. See
  # Activatable.
  test "posting active: \"\" re-renders with an error instead of a 500" do
    sign_in users(:stari_admin)
    room = rooms(:stari_301)

    patch staff_room_path(room), params: { room: { active: "" } }

    assert_response :unprocessable_content
    # stari_admin's locale is bs; rails-i18n supplies the Bosnian
    # ActiveRecord error vocabulary for "is not included in the list".
    assert_match "nije uključeno u listu", response.body
    assert room.reload.active?
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
