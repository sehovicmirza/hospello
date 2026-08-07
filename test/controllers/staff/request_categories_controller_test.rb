require "test_helper"

# See rooms_controller_test.rb's header comment for why count assertions
# below use `RequestCategory.unscoped.count`, not a bare `RequestCategory.count`.
class Staff::RequestCategoriesControllerTest < ActionDispatch::IntegrationTest
  test "a hotel admin sees the hotel's own categories, not another hotel's" do
    sign_in users(:stari_admin)

    get staff_request_categories_path

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(request_categories(:stari_wakeup))} td:first-child div", text: "Wake-up call"
    assert_select "##{ActionView::RecordIdentifier.dom_id(request_categories(:vrelo_wakeup))}", count: 0
  end

  test "plain staff can view categories but sees no add-category form" do
    sign_in users(:stari_staff)

    get staff_request_categories_path

    assert_response :success
    assert_select "form[action=?]", staff_request_categories_path, count: 0
  end

  # See rooms_controller_test.rb's "sees the add-room and bulk-add forms"
  # test for why this positive counterpart matters.
  test "a hotel admin sees the add-category form" do
    sign_in users(:stari_admin)

    get staff_request_categories_path

    assert_response :success
    assert_select "form[action=?]", staff_request_categories_path, count: 1
  end

  test "a hotel admin can add a category with a department and detail_fields" do
    sign_in users(:stari_admin)
    department = departments(:stari_reception)

    assert_difference -> { RequestCategory.unscoped.count }, 1 do
      post staff_request_categories_path, params: {
        request_category: {
          key: "newspaper", name: "Morning newspaper", department_id: department.id,
          detail_fields: [ "", "time" ]
        }
      }
    end

    assert_redirected_to staff_request_categories_path
    with_tenant(hotels(:stari_grad)) do
      category = hotels(:stari_grad).request_categories.find_by!(key: "newspaper")
      assert_equal department, category.department
      assert_equal %w[time], category.detail_fields
    end
  end

  test "a category may be created with no department" do
    sign_in users(:stari_admin)

    assert_difference -> { RequestCategory.unscoped.count }, 1 do
      post staff_request_categories_path, params: { request_category: { key: "no_dept", name: "No department" } }
    end

    assert_redirected_to staff_request_categories_path
    category = with_tenant(hotels(:stari_grad)) { hotels(:stari_grad).request_categories.find_by!(key: "no_dept") }
    assert_nil category.department_id
  end

  test "an unsupported detail_fields value re-renders with an error instead of a 500" do
    sign_in users(:stari_admin)

    assert_no_difference -> { RequestCategory.unscoped.count } do
      post staff_request_categories_path, params: { request_category: { key: "bad_fields", name: "Bad fields", detail_fields: [ "bogus" ] } }
    end

    assert_response :unprocessable_content
    assert_select "li", text: "Detail fields contains unsupported values: bogus"
  end

  test "adding a duplicate key re-renders with an error instead of a 500" do
    sign_in users(:stari_admin)

    assert_no_difference -> { RequestCategory.unscoped.count } do
      post staff_request_categories_path, params: { request_category: { key: request_categories(:stari_wakeup).key, name: "Dup" } }
    end

    assert_response :unprocessable_content
    assert_select "li", text: "Key has already been taken"
  end

  test "plain staff cannot add a category" do
    sign_in users(:stari_staff)

    assert_no_difference -> { RequestCategory.unscoped.count } do
      post staff_request_categories_path, params: { request_category: { key: "should_not_exist", name: "Nope" } }
    end

    assert_response :forbidden
  end

  test "a hotel admin can rename a category, change its department, and deactivate it" do
    sign_in users(:stari_admin)
    category = request_categories(:stari_wakeup)
    new_department = departments(:stari_housekeeping)

    patch staff_request_category_path(category), params: {
      request_category: { name: "Buđenje na poziv", department_id: new_department.id, active: false }
    }

    assert_redirected_to staff_request_categories_path
    category.reload
    assert_equal "Buđenje na poziv", category.name
    with_tenant(hotels(:stari_grad)) { assert_equal new_department, category.department }
    assert_not category.active?
  end

  test "plain staff cannot update a category" do
    sign_in users(:stari_staff)
    category = request_categories(:stari_wakeup)
    original_name = category.name

    patch staff_request_category_path(category), params: { request_category: { name: "HACKED" } }

    assert_response :forbidden
    assert_equal original_name, category.reload.name
  end

  test "a hotel admin can delete a category" do
    sign_in users(:stari_admin)
    category = with_tenant(hotels(:stari_grad)) { hotels(:stari_grad).request_categories.create!(key: "temp", name: "Temp") }

    assert_difference -> { RequestCategory.unscoped.count }, -1 do
      delete staff_request_category_path(category)
    end

    assert_redirected_to staff_request_categories_path
  end

  test "plain staff cannot delete a category" do
    sign_in users(:stari_staff)
    category = request_categories(:stari_wakeup)

    assert_no_difference -> { RequestCategory.unscoped.count } do
      delete staff_request_category_path(category)
    end

    assert_response :forbidden
  end

  test "a signed-out user is redirected to sign-in for every request-categories route" do
    category = request_categories(:stari_wakeup)

    staff_request_category_routes(category).each do |method, path|
      send(method, path)
      assert_redirected_to new_session_path, "expected a redirect for #{method.upcase} #{path}"
    end
  end

  test "a platform admin cannot reach any request-categories route" do
    sign_in users(:platform)
    category = request_categories(:stari_wakeup)

    staff_request_category_routes(category).each do |method, path|
      send(method, path)
      assert_response :forbidden, "expected 403 for #{method.upcase} #{path}"
    end
  end

  private
    def staff_request_category_routes(category)
      [
        [ :get, staff_request_categories_path ],
        [ :post, staff_request_categories_path ],
        [ :get, edit_staff_request_category_path(category) ],
        [ :patch, staff_request_category_path(category) ],
        [ :delete, staff_request_category_path(category) ]
      ]
    end
end
