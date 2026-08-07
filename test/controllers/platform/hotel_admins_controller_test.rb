require "test_helper"

class Platform::HotelAdminsControllerTest < ActionDispatch::IntegrationTest
  test "a platform admin can view the new admin form for a hotel" do
    sign_in users(:platform)

    get new_platform_hotel_hotel_admin_path(hotels(:vrelo))

    assert_response :success
  end

  test "a platform admin can create a hotel's first administrator" do
    sign_in users(:platform)
    hotel = hotels(:vrelo)

    # active: false is submitted deliberately: `active` isn't a permitted
    # param at all, so this proves it's actually ignored rather than merely
    # matching the users.active column default — the same default the
    # request would produce even if the controller silently honored a
    # hostile `active` param, which is exactly what made the original
    # `assert user.active?` unable to fail.
    assert_difference -> { User.count }, 1 do
      post platform_hotel_hotel_admins_path(hotel), params: { user: valid_user_params(active: false) }
    end

    user = User.find_by!(email_address: valid_user_params[:email_address])
    assert_redirected_to platform_hotel_path(hotel)
    assert user.hotel_admin?
    assert_equal hotel, user.hotel
    assert user.active?
    assert user.authenticate("password123")
  end

  test "creating a hotel admin writes an audit log with action hotel_admin.create" do
    sign_in users(:platform)
    hotel = hotels(:vrelo)

    assert_difference -> { AuditLog.count }, 1 do
      post platform_hotel_hotel_admins_path(hotel), params: { user: valid_user_params }
    end

    user = User.find_by!(email_address: valid_user_params[:email_address])
    log = AuditLog.last

    assert_equal "hotel_admin.create", log.action
    assert_equal user, log.target
    assert_equal hotel, log.hotel
    assert_equal users(:platform), log.actor_user
  end

  test "the email must be unique platform-wide" do
    sign_in users(:platform)
    hotel = hotels(:vrelo)
    taken_email = users(:stari_admin).email_address

    assert_no_difference -> { User.count } do
      post platform_hotel_hotel_admins_path(hotel), params: { user: valid_user_params(email_address: taken_email) }
    end

    assert_response :unprocessable_content
    assert_match "already been taken", response.body
  end

  test "an email is compared case-insensitively across the whole platform" do
    sign_in users(:platform)
    hotel = hotels(:vrelo)
    shouting_duplicate = users(:stari_admin).email_address.upcase

    assert_no_difference -> { User.count } do
      post platform_hotel_hotel_admins_path(hotel), params: { user: valid_user_params(email_address: shouting_duplicate) }
    end

    assert_response :unprocessable_content
  end

  test "a submitted role is ignored — the created user is always a hotel_admin" do
    sign_in users(:platform)
    hotel = hotels(:vrelo)

    # "staff" (unlike "platform_admin") is a role that would validate fine
    # against this hotel, so this isolates the controller's own server-side
    # role assignment from User's unrelated role/hotel cross-validation.
    post platform_hotel_hotel_admins_path(hotel), params: { user: valid_user_params(role: "staff") }

    user = User.find_by!(email_address: valid_user_params[:email_address])
    assert user.hotel_admin?
    assert_equal hotel, user.hotel
  end

  test "a submitted hotel_id is ignored — the new admin always belongs to the hotel in the URL" do
    sign_in users(:platform)
    hotel = hotels(:vrelo)
    other_hotel = hotels(:stari_grad)

    post platform_hotel_hotel_admins_path(hotel), params: { user: valid_user_params(hotel_id: other_hotel.id) }

    user = User.find_by!(email_address: valid_user_params[:email_address])
    assert_equal hotel, user.hotel
  end

  test "a hotel admin cannot reach the new or create hotel-admin routes" do
    sign_in users(:stari_admin)
    hotel = hotels(:vrelo)

    get new_platform_hotel_hotel_admin_path(hotel)
    assert_response :forbidden

    assert_no_difference -> { User.count } do
      post platform_hotel_hotel_admins_path(hotel), params: { user: valid_user_params }
    end
    assert_response :forbidden
  end

  test "a signed-out user is redirected to sign-in" do
    get new_platform_hotel_hotel_admin_path(hotels(:vrelo))

    assert_redirected_to new_session_path
  end

  private
    def valid_user_params(overrides = {})
      {
        name: "Nova Admin",
        email_address: "nova.admin@vrelo-bosne.example",
        password: "password123",
        password_confirmation: "password123"
      }.merge(overrides)
    end
end
