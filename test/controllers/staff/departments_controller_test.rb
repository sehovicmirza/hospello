require "test_helper"

# See rooms_controller_test.rb's header comment for why count assertions
# below use `Department.unscoped.count`, not a bare `Department.count`.
class Staff::DepartmentsControllerTest < ActionDispatch::IntegrationTest
  test "a hotel admin sees the hotel's own departments, not another hotel's" do
    sign_in users(:stari_admin)

    get staff_departments_path

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(departments(:stari_reception))} td", text: "Reception"
    assert_select "##{ActionView::RecordIdentifier.dom_id(departments(:vrelo_reception))}", count: 0
  end

  # The staff layout's nav previously rendered "Departments & categories" as
  # an inert `path: nil` placeholder (see staff_helper.rb); this pins that
  # the swap to a real path actually happened.
  test "the staff nav offers a working Departments & categories link" do
    sign_in users(:stari_admin)

    get staff_root_path

    assert_response :success
    assert_select "nav a[href=?]", staff_departments_path, text: "Departments & categories", count: 1
  end

  test "plain staff can view departments but sees no add-department form" do
    sign_in users(:stari_staff)

    get staff_departments_path

    assert_response :success
    assert_select "form[action=?]", staff_departments_path, count: 0
  end

  # See rooms_controller_test.rb's "sees the add-room and bulk-add forms"
  # test for why this positive counterpart matters — the "count: 0 for
  # staff" test above can't fail on its own if the form were broken for
  # everyone, admins included.
  test "a hotel admin sees the add-department form" do
    sign_in users(:stari_admin)

    get staff_departments_path

    assert_response :success
    assert_select "form[action=?]", staff_departments_path, count: 1
  end

  test "a hotel admin can add a department" do
    sign_in users(:stari_admin)

    assert_difference -> { Department.unscoped.count }, 1 do
      post staff_departments_path, params: { department: { name: "Concierge", position: 5 } }
    end

    assert_redirected_to staff_departments_path
    department = with_tenant(hotels(:stari_grad)) { hotels(:stari_grad).departments.find_by!(name: "Concierge") }
    assert_equal 5, department.position
  end

  test "adding a duplicate department name re-renders with an error instead of a 500" do
    sign_in users(:stari_admin)

    assert_no_difference -> { Department.unscoped.count } do
      post staff_departments_path, params: { department: { name: departments(:stari_reception).name } }
    end

    assert_response :unprocessable_content
    assert_select "li", text: "Name has already been taken"
  end

  test "plain staff cannot add a department" do
    sign_in users(:stari_staff)

    assert_no_difference -> { Department.unscoped.count } do
      post staff_departments_path, params: { department: { name: "Should not be created" } }
    end

    assert_response :forbidden
  end

  test "a hotel admin can rename, reorder, and deactivate a department" do
    sign_in users(:stari_admin)
    department = departments(:stari_reception)

    patch staff_department_path(department), params: { department: { name: "Front Desk", position: 9, active: false } }

    assert_redirected_to staff_departments_path
    department.reload
    assert_equal "Front Desk", department.name
    assert_equal 9, department.position
    assert_not department.active?
  end

  # Probed directly: active: "" casts to nil (ActiveModel::Type::Boolean),
  # and departments.active is null: false — unguarded, that reached Postgres
  # as an unrescued NotNullViolation (a 500) instead of a normal re-render.
  # See Activatable.
  test "posting active: \"\" re-renders with an error instead of a 500" do
    sign_in users(:stari_admin)
    department = departments(:stari_reception)

    patch staff_department_path(department), params: { department: { active: "" } }

    assert_response :unprocessable_content
    assert_match "is not included in the list", response.body
    assert department.reload.active?
  end

  test "plain staff cannot update a department" do
    sign_in users(:stari_staff)
    department = departments(:stari_reception)
    original_name = department.name

    patch staff_department_path(department), params: { department: { name: "HACKED" } }

    assert_response :forbidden
    assert_equal original_name, department.reload.name
  end

  test "a hotel admin can delete an unreferenced department" do
    sign_in users(:stari_admin)
    department = with_tenant(hotels(:stari_grad)) { hotels(:stari_grad).departments.create!(name: "Temp Dept") }

    assert_difference -> { Department.unscoped.count }, -1 do
      delete staff_department_path(department)
    end

    assert_redirected_to staff_departments_path
  end

  test "deleting a department still referenced by a request category fails gracefully, not with a 500" do
    sign_in users(:stari_admin)
    department = departments(:stari_housekeeping)
    assert with_tenant(hotels(:stari_grad)) { department.request_categories.any? },
      "fixture setup assumption: stari_housekeeping must be referenced"

    assert_no_difference -> { Department.unscoped.count } do
      delete staff_department_path(department)
    end

    assert_redirected_to staff_departments_path
    follow_redirect!
    assert_match "Cannot delete", response.body
    assert Department.unscoped.exists?(department.id)
  end

  test "plain staff cannot delete a department" do
    sign_in users(:stari_staff)
    department = departments(:stari_reception)

    assert_no_difference -> { Department.unscoped.count } do
      delete staff_department_path(department)
    end

    assert_response :forbidden
  end

  test "a signed-out user is redirected to sign-in for every departments route" do
    department = departments(:stari_reception)

    staff_department_routes(department).each do |method, path|
      send(method, path)
      assert_redirected_to new_session_path, "expected a redirect for #{method.upcase} #{path}"
    end
  end

  test "a platform admin cannot reach any departments route" do
    sign_in users(:platform)
    department = departments(:stari_reception)

    staff_department_routes(department).each do |method, path|
      send(method, path)
      assert_response :forbidden, "expected 403 for #{method.upcase} #{path}"
    end
  end

  private
    def staff_department_routes(department)
      [
        [ :get, staff_departments_path ],
        [ :post, staff_departments_path ],
        [ :get, edit_staff_department_path(department) ],
        [ :patch, staff_department_path(department) ],
        [ :delete, staff_department_path(department) ]
      ]
    end
end
