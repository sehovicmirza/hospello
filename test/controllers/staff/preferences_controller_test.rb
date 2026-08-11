require "test_helper"

# A staff member's own workspace language. The one thing this controller
# has to prove above everything else: it can change *your own* account and
# structurally cannot be made to touch anyone else's — there is no id, no
# user_id, nothing in the route or the params to name a colleague with (see
# config/routes.rb and Staff::PreferencesController).
class Staff::PreferencesControllerTest < ActionDispatch::IntegrationTest
  test "any active staff member — not just a hotel_admin — can see their own preferences" do
    sign_in users(:stari_staff)

    get edit_staff_preferences_path

    assert_response :success
    assert_select "select#user_locale"
  end

  test "a staff member can change their own workspace language" do
    user = users(:stari_staff)
    assert_equal "bs", user.locale, "fixture assumption: stari_staff starts in Bosnian"
    sign_in user

    patch staff_preferences_path, params: { user: { locale: "en" } }

    assert_redirected_to edit_staff_preferences_path
    assert_equal "en", user.reload.locale
  end

  # The confirmation has to be readable at the point the user actually sees
  # it — built under the *new* locale, not whichever one this request
  # started under (see Staff::PreferencesController#update). Without that,
  # a user switching from Bosnian to English would see one leftover
  # Bosnian sentence on an otherwise-English page.
  test "the confirmation after switching language is itself already in the new language" do
    sign_in users(:stari_staff) # locale: bs

    patch staff_preferences_path, params: { user: { locale: "en" } }
    follow_redirect!

    # staff.preferences.update.updated — English and Bosnian text
    # (config/locales/staff.{en,bs}.yml), pasted literally.
    assert_match "Language updated.", response.body
    assert_no_match "Jezik ažuriran.", response.body
  end

  test "the reverse direction: switching to Bosnian shows a Bosnian confirmation" do
    sign_in users(:vrelo_staff) # locale: en

    patch staff_preferences_path, params: { user: { locale: "bs" } }
    follow_redirect!

    assert_match "Jezik ažuriran.", response.body
    assert_no_match "Language updated.", response.body
  end

  test "an invalid locale value is refused rather than silently accepted" do
    user = users(:stari_staff)
    sign_in user

    patch staff_preferences_path, params: { user: { locale: "fr" } }

    assert_response :unprocessable_content
    assert_equal "bs", user.reload.locale
  end

  # The guarantee this task exists to prove, checked empirically rather
  # than only by reading the controller: a colleague's row is untouched by
  # a request this account made.
  test "changing your own language never changes anyone else's" do
    acting = users(:stari_staff)
    colleague = users(:stari_admin)
    original_colleague_locale = colleague.locale
    sign_in acting

    patch staff_preferences_path, params: { user: { locale: "en" } }

    assert_equal original_colleague_locale, colleague.reload.locale
  end

  # There is no id in this route for a request to smuggle at all (unlike
  # Staff::UsersController#update, which takes one and is hotel_admin-gated
  # — see that controller's own test for the 403 case) — this proves a
  # crafted `user_id`/`id` param in the body is simply not read.
  test "a smuggled user id in the params has no effect — the route has nowhere to put one" do
    acting = users(:stari_staff)
    colleague = users(:stari_admin)
    sign_in acting

    patch staff_preferences_path, params: { user: { locale: "en" }, id: colleague.id, user_id: colleague.id }

    assert_equal "en", acting.reload.locale
    assert_not_equal "en", colleague.reload.locale
  end

  test "a signed-out user is redirected to sign-in" do
    get edit_staff_preferences_path
    assert_redirected_to new_session_path

    patch staff_preferences_path, params: { user: { locale: "en" } }
    assert_redirected_to new_session_path
  end
end
