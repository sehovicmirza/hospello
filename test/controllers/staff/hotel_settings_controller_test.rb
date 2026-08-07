require "test_helper"

class Staff::HotelSettingsControllerTest < ActionDispatch::IntegrationTest
  test "a hotel admin can view the edit form pre-filled with the hotel's own data" do
    sign_in users(:stari_admin)

    get edit_staff_hotel_settings_path

    assert_response :success
    assert_select "input[name='hotel[name]'][value='#{hotels(:stari_grad).name}']"
  end

  test "a hotel admin can update the hotel's branding and profile" do
    sign_in users(:stari_admin)
    hotel = hotels(:stari_grad)

    patch staff_hotel_settings_path, params: { hotel: valid_settings_params }

    assert_redirected_to edit_staff_hotel_settings_path
    hotel.reload
    assert_equal valid_settings_params[:name], hotel.name
    assert_equal "America/New_York", hotel.timezone
    assert_equal "en", hotel.staff_locale
    assert_equal "#112233", hotel.primary_color
    assert_equal "#445566", hotel.secondary_color
    assert_equal "Selma Test", hotel.concierge_name
    assert_equal "Updated welcome message for testing.", hotel.welcome_message
    assert_equal "+387 33 999 999", hotel.contact_phone
    assert_equal "Updated notes for testing.", hotel.contact_notes
    assert_equal "12:00", hotel.checkout_time
    assert_equal "updated@stari-grad.example", hotel.escalation_email
    assert_equal 90, hotel.overdue_after_minutes
  end

  test "plain staff cannot view the edit form" do
    sign_in users(:stari_staff)

    get edit_staff_hotel_settings_path

    assert_response :forbidden
  end

  test "plain staff cannot update the hotel" do
    sign_in users(:stari_staff)
    hotel = hotels(:stari_grad)
    original_concierge_name = hotel.concierge_name

    patch staff_hotel_settings_path, params: { hotel: valid_settings_params }

    assert_response :forbidden
    assert_equal original_concierge_name, hotel.reload.concierge_name
  end

  test "plain staff can still reach the dashboard" do
    sign_in users(:stari_staff)

    get staff_root_path

    assert_response :success
  end

  test "posting platform-only attributes from the staff form leaves them unchanged" do
    sign_in users(:stari_admin)
    hotel = hotels(:stari_grad)
    assert hotel.powered_by_visible?
    assert hotel.ai_enabled?
    assert hotel.active?
    original_slug = hotel.slug
    original_budget = hotel.ai_daily_token_budget

    patch staff_hotel_settings_path, params: {
      hotel: valid_settings_params.merge(
        slug: "hijacked-slug",
        status: "suspended",
        powered_by_visible: "false",
        ai_enabled: "false",
        ai_daily_token_budget: 1
      )
    }

    # The request must actually have succeeded (proving the fields below were
    # dropped by strong params, not that the whole update silently failed).
    assert_redirected_to edit_staff_hotel_settings_path
    hotel.reload
    assert_equal "Selma Test", hotel.concierge_name

    assert_equal original_slug, hotel.slug
    assert hotel.active?
    assert hotel.powered_by_visible?
    assert hotel.ai_enabled?
    assert_equal original_budget, hotel.ai_daily_token_budget
  end

  test "a hotel A admin updating settings never touches hotel B — there is no id in the path" do
    sign_in users(:stari_admin)
    hotel_b = hotels(:vrelo)
    original_name = hotel_b.name
    original_concierge_name = hotel_b.concierge_name
    original_primary_color = hotel_b.primary_color

    patch staff_hotel_settings_path, params: { hotel: valid_settings_params }

    hotel_b.reload
    assert_equal original_name, hotel_b.name
    assert_equal original_concierge_name, hotel_b.concierge_name
    assert_equal original_primary_color, hotel_b.primary_color
  end

  test "a signed-out user is redirected to sign-in for every staff route" do
    staff_routes.each do |method, path|
      send(method, path)
      assert_redirected_to new_session_path, "expected a redirect for #{method.upcase} #{path}"
    end
  end

  test "a platform admin cannot reach any staff route" do
    sign_in users(:platform)

    staff_routes.each do |method, path|
      send(method, path)
      assert_response :forbidden, "expected 403 for #{method.upcase} #{path}"
    end
  end

  private
    def valid_settings_params(overrides = {})
      {
        name: "Hotel Stari Grad Renamed",
        timezone: "America/New_York",
        staff_locale: "en",
        primary_color: "#112233",
        secondary_color: "#445566",
        concierge_name: "Selma Test",
        welcome_message: "Updated welcome message for testing.",
        contact_phone: "+387 33 999 999",
        contact_notes: "Updated notes for testing.",
        checkout_time: "12:00",
        escalation_email: "updated@stari-grad.example",
        overdue_after_minutes: 90
      }.merge(overrides)
    end

    # Every route this task adds — reused across actor types, mirroring
    # test/controllers/platform/hotels_controller_test.rb's own loop helper.
    # Unlike the platform namespace, plain staff are not uniformly refused
    # here (they may reach the dashboard), so that distinction is tested
    # explicitly above rather than folded into this loop.
    def staff_routes
      [
        [ :get, staff_root_path ],
        [ :get, edit_staff_hotel_settings_path ],
        [ :patch, staff_hotel_settings_path ]
      ]
    end
end
