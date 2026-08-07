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
end
