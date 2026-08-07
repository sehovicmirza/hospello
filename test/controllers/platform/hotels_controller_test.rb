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

    # Scoped to each hotel's own row and matched on exact element text, not a
    # page-wide substring: every digit 0-9 already appears somewhere in the
    # page's static Tailwind classes (e.g. "px-4 py-3", "max-w-5xl"), so a
    # bare `assert_match "2", response.body` passes regardless of what the
    # count actually renders as. staff_locale is "staff" only (not
    # hotel_admin) — stari_grad's fixtures are one admin, one staff.
    assert_select "##{ActionView::RecordIdentifier.dom_id(hotels(:stari_grad))}" do
      assert_select "span", text: "Active", count: 1
      assert_select "td", text: hotels(:stari_grad).users.staff.count.to_s, count: 1
    end

    assert_select "##{ActionView::RecordIdentifier.dom_id(hotels(:vrelo))}" do
      assert_select "span", text: "Suspended", count: 1
    end
  end

  test "index shows whether each hotel already has an active first admin" do
    # Deactivating (not destroying) vrelo's admin exercises the same query
    # this pins from both directions: a hotel with an active admin reads
    # "Yes", and a hotel whose only admin exists but is deactivated must read
    # "Not yet", not a stale "Yes" — @hotel_ids_with_admin has to scope by
    # User.hotel_admin.active, not just User.hotel_admin.
    users(:vrelo_admin).update!(active: false)
    sign_in users(:platform)

    get platform_hotels_path

    assert_response :success

    assert_select "##{ActionView::RecordIdentifier.dom_id(hotels(:stari_grad))}" do
      assert_select "span", text: "Yes", count: 1
    end

    assert_select "##{ActionView::RecordIdentifier.dom_id(hotels(:vrelo))}" do
      assert_select "span", text: "Not yet", count: 1
    end
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
    assert_equal "America/New_York", hotel.timezone
    assert_not hotel.powered_by_visible?
    assert_not hotel.ai_enabled?
    assert_equal 250_000, hotel.ai_daily_token_budget
    assert_equal "ops@two-rivers.example", hotel.escalation_email

    # Pins the platform layout being wired up (`layout "platform"` on
    # Platform::BaseController): layouts/application.html.erb has no flash
    # block at all, so before that line existed this notice silently never
    # rendered. Only a system test caught it originally — this makes it a
    # deterministic, one-request regression guard.
    follow_redirect!
    assert_match "#{hotel.name} created.", response.body
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

  test "suspending an already-suspended hotel is a no-op, not a second audit row" do
    sign_in users(:platform)
    hotel = hotels(:stari_grad)
    hotel.suspended!

    assert_no_difference -> { AuditLog.count } do
      patch suspend_platform_hotel_path(hotel)
    end

    assert_redirected_to platform_hotel_path(hotel)
    assert hotel.reload.suspended?
  end

  test "reactivating an already-active hotel is a no-op, not a second audit row" do
    sign_in users(:platform)
    hotel = hotels(:stari_grad)
    assert hotel.active?

    assert_no_difference -> { AuditLog.count } do
      patch activate_platform_hotel_path(hotel)
    end

    assert_redirected_to platform_hotel_path(hotel)
    assert hotel.reload.active?
  end

  test "suspending a hotel that is invalid for an unrelated reason flashes instead of raising" do
    sign_in users(:platform)
    hotel = hotels(:stari_grad)
    # Bypasses validations to reach an invalid-but-persisted row, the way a
    # hotel could end up invalid for a reason #suspend has nothing to do
    # with (e.g. a bad timezone from data cleanup). #suspend must not use a
    # bang method here — update! /suspended! would raise RecordInvalid and
    # 500 instead of reporting the problem.
    hotel.update_column(:staff_locale, "invalid-locale")

    patch suspend_platform_hotel_path(hotel)

    assert_response :redirect
    follow_redirect!
    assert_match "could not be suspended", response.body
    assert_not hotel.reload.suspended?
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
        # Deliberately not the "timezone" column's own DB default
        # (Europe/Sarajevo) — assertions that check the saved value against
        # this default must fail if :timezone were dropped from hotel_params,
        # not pass by coincidence.
        timezone: "America/New_York",
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
