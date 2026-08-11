require "test_helper"

# The trap this task's brief calls out by name: the staff workspace's
# language is a property of the *user* (User#locale), never of the hotel
# (Hotel#staff_locale — a different axis entirely, the translation target
# for guest<->staff overlays). A Bosnian receptionist and an
# English-speaking manager work the same hotel and must each see their own
# language.
#
# This is the one test in the suite that actually proves that distinction.
# Every other staff test signs in as stari_admin/stari_staff (both
# locale: bs, at a hotel whose staff_locale is *also* bs) or
# vrelo_admin/vrelo_staff (both locale: en, at a hotel whose staff_locale is
# *also* en — see test/fixtures/hotels.yml and users.yml). Keying the
# render off Current.hotel.staff_locale instead of Current.user.locale
# would pass every one of those tests too, because the two values happen to
# agree in both fixture hotels. Only a user whose own locale *disagrees*
# with their hotel's staff_locale can catch that mistake — so this test
# creates one rather than relying on the coincidence in the shared fixtures.
#
# Expected strings are literals copied from config/locales/staff.*.yml, not
# a second call to I18n.t against the file under test — the same discipline
# test/controllers/guest/localization_test.rb documents for the guest side.
class Staff::LocalizationTest < ActionDispatch::IntegrationTest
  test "a staff member reads the workspace in their own locale even when it disagrees with the hotel's staff_locale" do
    hotel = hotels(:stari_grad)
    assert_equal "bs", hotel.staff_locale, "fixture assumption: stari_grad's staff_locale is bs"

    english_reader = User.create!(
      hotel: hotel, name: "English Reader", role: :staff, locale: "en",
      email_address: "english.reader@stari-grad.example",
      password: "password123", password_confirmation: "password123"
    )
    sign_in english_reader

    get staff_root_path

    assert_response :success
    # staff.nav.dashboard, config/locales/staff.en.yml — would read
    # "Početna" (the Bosnian for it) if the render followed the hotel's
    # staff_locale instead of this user's own.
    assert_select "nav a[href=?]", staff_root_path, text: "Dashboard"
    assert_select "nav a", text: "Početna", count: 0
  end

  test "the reverse direction: a Bosnian-reading user at the English-staff_locale hotel" do
    hotel = hotels(:vrelo)
    assert_equal "en", hotel.staff_locale, "fixture assumption: vrelo's staff_locale is en"

    bosnian_reader = User.create!(
      hotel: hotel, name: "Bosanski Čitalac", role: :staff, locale: "bs",
      email_address: "bosanski.citalac@vrelo-bosne.example",
      password: "password123", password_confirmation: "password123"
    )
    sign_in bosnian_reader

    get staff_root_path

    assert_response :success
    # staff.nav.dashboard, config/locales/staff.bs.yml.
    assert_select "nav a[href=?]", staff_root_path, text: "Početna"
    assert_select "nav a", text: "Dashboard", count: 0
  end

  test "two staff members at the same hotel, different locales, see different languages" do
    hotel = hotels(:stari_grad)

    sign_in users(:stari_admin) # locale: bs, per fixtures
    get staff_root_path
    assert_response :success
    assert_select "h1", text: /Dobrodošli/ # staff.dashboard.show.welcome, bs

    # sign_in overwrites the session cookie outright, so no explicit
    # sign-out step is needed between the two — see test_helper.rb.
    manager = User.create!(
      hotel: hotel, name: "English Manager", role: :hotel_admin, locale: "en",
      email_address: "english.manager@stari-grad.example",
      password: "password123", password_confirmation: "password123"
    )
    sign_in manager
    get staff_root_path
    assert_response :success
    assert_select "h1", text: /Welcome/ # staff.dashboard.show.welcome, en
  end
end
