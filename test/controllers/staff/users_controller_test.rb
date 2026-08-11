require "test_helper"

# Staff accounts are the only screen in the product that creates users, and
# the only roles it may create are staff and hotel_admin — a platform_admin
# minted here would be a cross-hotel account created by a hotel employee.
# Unlike HotelConfigurationPolicy's resources (rooms, departments,
# categories), plain staff get no read access at all: every route here is
# hotel_admin-only.
class Staff::UsersControllerTest < ActionDispatch::IntegrationTest
  test "a hotel admin sees the hotel's own staff, not another hotel's" do
    sign_in users(:stari_admin)

    get staff_users_path

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(users(:stari_staff))} td", text: users(:stari_staff).name
    # vrelo's staff must never leak into stari_grad's list, scoped to a row
    # (not a page-wide substring).
    assert_select "##{ActionView::RecordIdentifier.dom_id(users(:vrelo_staff))}", count: 0
  end

  test "the staff nav offers a working Staff link to a hotel admin" do
    sign_in users(:stari_admin)

    get staff_root_path

    assert_response :success
    # stari_admin reads the staff workspace in Bosnian — see fixtures.
    assert_select "nav a[href=?]", staff_users_path, text: "Osoblje", count: 1
  end

  # Plain staff have no read access to this screen at all (unlike Rooms and
  # Departments, which are read-only for them) — the nav link would just
  # 403, so it must not render for this role. See staff_helper.rb's
  # "Hotel settings" precedent for the same convention.
  test "plain staff sees no Staff nav link" do
    sign_in users(:stari_staff)

    get staff_root_path

    assert_response :success
    assert_select "nav a[href=?]", staff_users_path, count: 0
  end

  test "a hotel admin can view the new user form" do
    sign_in users(:stari_admin)

    get new_staff_user_path

    assert_response :success
  end

  test "a hotel_admin can create a staff user, and a hotel_id posted in the form is ignored" do
    sign_in users(:stari_admin)
    other_hotel = hotels(:vrelo)

    assert_difference -> { User.count }, 1 do
      post staff_users_path, params: { user: valid_user_params(hotel_id: other_hotel.id) }
    end

    user = User.find_by!(email_address: valid_user_params[:email_address])
    assert_redirected_to staff_users_path
    assert user.staff?
    assert_equal hotels(:stari_grad), user.hotel
    assert user.active?
    assert user.authenticate("password123")
  end

  test "a hotel_admin can create a fellow hotel_admin" do
    sign_in users(:stari_admin)

    post staff_users_path, params: {
      user: valid_user_params(role: "hotel_admin", email_address: "new.admin@stari-grad.example")
    }

    user = User.find_by!(email_address: "new.admin@stari-grad.example")
    assert user.hotel_admin?
    assert_equal hotels(:stari_grad), user.hotel
  end

  test "creating a user writes an audit log with action user.create" do
    sign_in users(:stari_admin)

    assert_difference -> { AuditLog.count }, 1 do
      post staff_users_path, params: { user: valid_user_params }
    end

    user = User.find_by!(email_address: valid_user_params[:email_address])
    log = AuditLog.last

    assert_equal "user.create", log.action
    assert_equal user, log.target
    assert_equal hotels(:stari_grad), log.hotel
    assert_equal users(:stari_admin), log.actor_user
  end

  # "staff" (unlike "platform_admin") is a role that would validate fine
  # against this hotel, so the platform_admin case below isolates the
  # controller's own role whitelist from User's unrelated role/hotel
  # cross-validation — see platform/hotel_admins_controller_test.rb for the
  # same reasoning.
  test "a hotel_admin cannot create a platform_admin — the role is ignored and the user is created as staff" do
    sign_in users(:stari_admin)

    assert_difference -> { User.count }, 1 do
      post staff_users_path, params: { user: valid_user_params(role: "platform_admin") }
    end

    user = User.find_by!(email_address: valid_user_params[:email_address])
    assert user.staff?
    assert_not user.platform_admin?
    assert_equal hotels(:stari_grad), user.hotel
  end

  test "creating a user with a taken email re-renders with an error instead of a 500" do
    sign_in users(:stari_admin)
    taken_email = users(:stari_staff).email_address

    assert_no_difference -> { User.count } do
      post staff_users_path, params: { user: valid_user_params(email_address: taken_email) }
    end

    assert_response :unprocessable_content
    # stari_admin's locale is bs; rails-i18n supplies the Bosnian
    # ActiveRecord error vocabulary for "has already been taken".
    assert_match "već zauzet", response.body
  end

  # Probed directly: password: "a" used to be accepted here with no minimum
  # length at all (has_secure_password only requires presence) — see
  # User::MINIMUM_PASSWORD_LENGTH.
  test "a password shorter than the minimum re-renders with an error instead of being accepted" do
    sign_in users(:stari_admin)

    assert_no_difference -> { User.count } do
      post staff_users_path, params: { user: valid_user_params(password: "a", password_confirmation: "a") }
    end

    assert_response :unprocessable_content
    # stari_admin's locale is bs; rails-i18n supplies the Bosnian
    # ActiveRecord error vocabulary for "too short".
    assert_match "prekratko", response.body
  end

  # Probed directly: active: "" casts to nil (ActiveModel::Type::Boolean),
  # and users.active is null: false — unguarded, that reached Postgres as an
  # unrescued NotNullViolation (a 500) instead of a normal re-render. See
  # Activatable. Also proves self_deactivation?'s own boolean cast of the
  # same param doesn't mistake "" for a deactivation attempt and block on
  # the wrong error first.
  test "posting active: \"\" re-renders with an error instead of a 500" do
    sign_in users(:stari_admin)
    target = users(:stari_staff)

    patch staff_user_path(target), params: { user: { active: "" } }

    assert_response :unprocessable_content
    # stari_admin's locale is bs; rails-i18n supplies the Bosnian
    # ActiveRecord error vocabulary for "is not included in the list".
    assert_match "nije uključeno u listu", response.body
    assert target.reload.active?
  end

  test "a hotel_admin can deactivate a user; a deactivated user cannot sign in" do
    sign_in users(:stari_admin)
    target = users(:stari_staff)
    assert target.can_sign_in?, "fixture setup assumption: stari_staff starts able to sign in"

    patch staff_user_path(target), params: { user: { active: false } }

    assert_redirected_to staff_users_path
    target.reload
    assert_not target.active?
    assert_not target.can_sign_in?
  end

  # Task 1's review found that deactivation alone does not revoke a live
  # session, because sessions are 20-year permanent cookies with no expiry
  # and User#can_sign_in? only gates *new* logins. A "deactivate someone who
  # left" button that leaves their current browser tab signed in doesn't
  # actually cut off access, so this controller also destroys the target's
  # sessions on the active-true -> active-false transition.
  test "deactivating a user destroys their existing sessions" do
    sign_in users(:stari_admin)
    target = users(:stari_staff)
    target.sessions.create!
    assert_equal 1, target.sessions.count

    patch staff_user_path(target), params: { user: { active: false } }

    assert_equal 0, target.sessions.count
  end

  test "deactivating a user writes an audit log with action user.deactivate" do
    sign_in users(:stari_admin)
    target = users(:stari_staff)

    assert_difference -> { AuditLog.count }, 1 do
      patch staff_user_path(target), params: { user: { active: false } }
    end

    log = AuditLog.last
    assert_equal "user.deactivate", log.action
    assert_equal target, log.target
    assert_equal hotels(:stari_grad), log.hotel
    assert_equal users(:stari_admin), log.actor_user
  end

  test "a hotel_admin can reactivate a previously deactivated user, with no audit log entry" do
    sign_in users(:stari_admin)
    target = users(:stari_staff)
    target.update!(active: false)

    assert_no_difference -> { AuditLog.count } do
      patch staff_user_path(target), params: { user: { active: true } }
    end

    assert_redirected_to staff_users_path
    assert target.reload.active?
  end

  # locale (Slice 5 Task 4) is the one addition to what's editable here —
  # deliberately, and separately tested below — name and role never are.
  test "updating a user cannot change their name or role" do
    sign_in users(:stari_admin)
    target = users(:stari_staff)
    original_name = target.name

    patch staff_user_path(target), params: { user: { active: true, name: "Hacked Name", role: "hotel_admin" } }

    target.reload
    assert_equal original_name, target.name
    assert target.staff?
  end

  # The admin side of the way in this task adds: a hotel_admin may set a
  # colleague's workspace language for them (e.g. onboarding someone who
  # won't set it up themselves) — the counterpart to
  # Staff::PreferencesController, which lets a user set only their own.
  test "a hotel_admin can set a colleague's workspace language" do
    sign_in users(:stari_admin)
    target = users(:stari_staff)
    assert_equal "bs", target.locale, "fixture assumption"

    patch staff_user_path(target), params: { user: { locale: "en" } }

    assert_redirected_to staff_users_path
    assert_equal "en", target.reload.locale
  end

  test "a new staff account is created with the language the admin chose for it" do
    sign_in users(:stari_admin)

    post staff_users_path, params: { user: valid_user_params(locale: "en") }

    user = User.find_by!(email_address: valid_user_params[:email_address])
    assert_equal "en", user.locale
  end

  test "an unrecognised locale is refused when creating a staff account, same as any other invalid field" do
    sign_in users(:stari_admin)

    assert_no_difference -> { User.count } do
      post staff_users_path, params: { user: valid_user_params(locale: "fr") }
    end

    assert_response :unprocessable_content
  end

  test "a hotel_admin cannot deactivate their own account" do
    admin = users(:stari_admin)
    sign_in admin

    assert_no_difference -> { AuditLog.count } do
      patch staff_user_path(admin), params: { user: { active: false } }
    end

    assert admin.reload.active?
    assert_redirected_to staff_users_path
    follow_redirect!
    # admin (stari_admin) reads the staff workspace in Bosnian — see
    # fixtures. staff.users.update.self_deactivation_blocked,
    # config/locales/staff.bs.yml.
    assert_match "Ne možete deaktivirati svoj vlastiti nalog", response.body
  end

  # The brief only requires a self-deactivation lock-out guard. A hotel_admin
  # deactivating a *different* hotel_admin is deliberately left unrestricted
  # in this slice — see task-5-report.md for why no "last active admin"
  # guard was added.
  test "a hotel_admin can deactivate a different hotel_admin" do
    sign_in users(:stari_admin)
    other_admin = User.create!(
      hotel: hotels(:stari_grad), name: "Second Admin", role: :hotel_admin,
      email_address: "second.admin@stari-grad.example",
      password: "password123", password_confirmation: "password123"
    )

    patch staff_user_path(other_admin), params: { user: { active: false } }

    assert_redirected_to staff_users_path
    assert_not other_admin.reload.active?
  end

  test "a plain staff user gets 403 on every users route" do
    sign_in users(:stari_staff)
    target = users(:stari_admin)

    staff_user_routes(target).each do |method, path|
      send(method, path, params: method == :post || method == :patch ? { user: { name: "x" } } : nil)
      assert_response :forbidden, "expected 403 for #{method.upcase} #{path}"
    end
  end

  test "a signed-out user is redirected to sign-in for every users route" do
    target = users(:stari_staff)

    staff_user_routes(target).each do |method, path|
      send(method, path)
      assert_redirected_to new_session_path, "expected a redirect for #{method.upcase} #{path}"
    end
  end

  test "a platform admin cannot reach any users route" do
    sign_in users(:platform)
    target = users(:stari_staff)

    staff_user_routes(target).each do |method, path|
      send(method, path)
      assert_response :forbidden, "expected 403 for #{method.upcase} #{path}"
    end
  end

  private
    def valid_user_params(overrides = {})
      {
        name: "Nova Staff",
        email_address: "nova.staff@stari-grad.example",
        password: "password123",
        password_confirmation: "password123",
        role: "staff"
      }.merge(overrides)
    end

    def staff_user_routes(user)
      [
        [ :get, staff_users_path ],
        [ :get, new_staff_user_path ],
        [ :post, staff_users_path ],
        [ :get, edit_staff_user_path(user) ],
        [ :patch, staff_user_path(user) ]
      ]
    end
end
