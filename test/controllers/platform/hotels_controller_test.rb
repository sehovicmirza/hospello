require "test_helper"

class Platform::HotelsControllerTest < ActionDispatch::IntegrationTest
  test "a platform admin can list hotels" do
    sign_in users(:platform)

    get platform_hotels_path

    assert_response :success
    assert_match hotels(:stari_grad).name, response.body
    assert_match hotels(:vrelo).name, response.body
  end

  test "index shows an empty state when there are no hotels yet" do
    Hotel.destroy_all
    sign_in users(:platform)

    get platform_hotels_path

    assert_response :success
    assert_match "No hotels yet", response.body
  end

  test "index reflects each hotel's status and staff count" do
    hotels(:vrelo).suspended!
    sign_in users(:platform)

    get platform_hotels_path

    assert_response :success
    assert_match "Active", response.body
    assert_match "Suspended", response.body
    assert_match hotels(:stari_grad).users.count.to_s, response.body
  end

  test "a platform admin can view the new hotel form" do
    sign_in users(:platform)

    get new_platform_hotel_path

    assert_response :success
  end

  test "a platform admin can create a hotel" do
    sign_in users(:platform)

    assert_difference -> { Hotel.count }, 1 do
      post platform_hotels_path, params: { hotel: valid_hotel_params }
    end

    hotel = Hotel.find_by!(slug: valid_hotel_params[:slug])
    assert_redirected_to platform_hotel_path(hotel)
    assert_equal valid_hotel_params[:name], hotel.name
    assert_equal "bs", hotel.staff_locale
    assert_equal "Europe/Sarajevo", hotel.timezone
    assert_not hotel.powered_by_visible?
    assert_not hotel.ai_enabled?
    assert_equal 250_000, hotel.ai_daily_token_budget
    assert_equal "ops@two-rivers.example", hotel.escalation_email
  end

  test "creating a hotel writes an audit log with action hotel.create" do
    sign_in users(:platform)

    assert_difference -> { AuditLog.count }, 1 do
      post platform_hotels_path, params: { hotel: valid_hotel_params }
    end

    hotel = Hotel.find_by!(slug: valid_hotel_params[:slug])
    log = AuditLog.last

    assert_equal "hotel.create", log.action
    assert_equal users(:platform), log.actor_user
    assert_equal hotel, log.hotel
    assert_equal hotel, log.target
  end

  test "creating a hotel with invalid attributes re-renders the form without saving" do
    sign_in users(:platform)

    assert_no_difference -> { Hotel.count } do
      post platform_hotels_path, params: { hotel: valid_hotel_params(name: "") }
    end

    assert_response :unprocessable_content
    assert_match "blank", response.body
  end

  test "a platform admin can view the edit form for a hotel" do
    sign_in users(:platform)

    get edit_platform_hotel_path(hotels(:stari_grad))

    assert_response :success
    assert_match hotels(:stari_grad).name, response.body
  end

  test "a platform admin can update a hotel's identity and platform switches" do
    sign_in users(:platform)
    hotel = hotels(:stari_grad)

    patch platform_hotel_path(hotel), params: {
      hotel: {
        name: "Hotel Stari Grad Renamed",
        slug: hotel.slug,
        timezone: hotel.timezone,
        staff_locale: hotel.staff_locale,
        powered_by_visible: "false",
        ai_enabled: "true",
        ai_daily_token_budget: 999_000,
        escalation_email: "front-desk@stari-grad.example"
      }
    }

    assert_redirected_to platform_hotel_path(hotel)
    hotel.reload
    assert_equal "Hotel Stari Grad Renamed", hotel.name
    assert_not hotel.powered_by_visible?
    assert_equal 999_000, hotel.ai_daily_token_budget
    assert_equal "front-desk@stari-grad.example", hotel.escalation_email
  end

  test "updating a hotel does not allow changing status directly — only #suspend/#activate may" do
    sign_in users(:platform)
    hotel = hotels(:stari_grad)
    assert hotel.active?

    patch platform_hotel_path(hotel), params: { hotel: { name: hotel.name, status: "suspended" } }

    assert hotel.reload.active?, "status must only change via the dedicated suspend/activate actions"
  end

  test "a platform admin can suspend an active hotel" do
    sign_in users(:platform)
    hotel = hotels(:stari_grad)
    assert hotel.active?

    assert_difference -> { AuditLog.count }, 1 do
      patch suspend_platform_hotel_path(hotel)
    end

    assert hotel.reload.suspended?
    assert_redirected_to platform_hotel_path(hotel)

    log = AuditLog.last
    assert_equal "hotel.suspend", log.action
    assert_equal hotel, log.hotel
    assert_equal hotel, log.target
    assert_equal users(:platform), log.actor_user
  end

  test "a platform admin can reactivate a suspended hotel" do
    sign_in users(:platform)
    hotel = hotels(:vrelo)
    hotel.suspended!

    assert_difference -> { AuditLog.count }, 1 do
      patch activate_platform_hotel_path(hotel)
    end

    assert hotel.reload.active?
    assert_redirected_to platform_hotel_path(hotel)

    log = AuditLog.last
    assert_equal "hotel.activate", log.action
    assert_equal hotel, log.hotel
    assert_equal hotel, log.target
    assert_equal users(:platform), log.actor_user
  end

  test "a platform admin can view a hotel's show page" do
    sign_in users(:platform)

    get platform_hotel_path(hotels(:stari_grad))

    assert_response :success
    assert_match hotels(:stari_grad).name, response.body
  end

  test "hotel admin cannot reach any platform route" do
    sign_in users(:stari_admin)

    platform_routes(hotels(:vrelo)).each do |method, path|
      send(method, path)
      assert_response :forbidden, "expected 403 for #{method.upcase} #{path}"
    end
  end

  test "plain staff cannot reach any platform route" do
    sign_in users(:stari_staff)

    platform_routes(hotels(:vrelo)).each do |method, path|
      send(method, path)
      assert_response :forbidden, "expected 403 for #{method.upcase} #{path}"
    end
  end

  test "a signed-out user is redirected to sign-in for every platform route" do
    platform_routes(hotels(:vrelo)).each do |method, path|
      send(method, path)
      assert_redirected_to new_session_path, "expected a redirect for #{method.upcase} #{path}"
    end
  end

  private
    def valid_hotel_params(overrides = {})
      {
        name: "Hotel Two Rivers",
        slug: "two-rivers",
        timezone: "Europe/Sarajevo",
        staff_locale: "bs",
        powered_by_visible: "false",
        ai_enabled: "false",
        ai_daily_token_budget: 250_000,
        escalation_email: "ops@two-rivers.example"
      }.merge(overrides)
    end

    # Every route this task adds, across both controllers in the namespace —
    # the 403/redirect boundary is asserted here once and reused, so it stays
    # exhaustive as routes are added instead of drifting from the brief's
    # example (which showed only three of these routes).
    def platform_routes(hotel)
      [
        [ :get,   platform_hotels_path ],
        [ :get,   new_platform_hotel_path ],
        [ :post,  platform_hotels_path ],
        [ :get,   platform_hotel_path(hotel) ],
        [ :get,   edit_platform_hotel_path(hotel) ],
        [ :patch, platform_hotel_path(hotel) ],
        [ :patch, suspend_platform_hotel_path(hotel) ],
        [ :patch, activate_platform_hotel_path(hotel) ],
        [ :get,   new_platform_hotel_hotel_admin_path(hotel) ],
        [ :post,  platform_hotel_hotel_admins_path(hotel) ]
      ]
    end
end
