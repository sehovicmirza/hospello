require "application_system_test_case"

# Locators below use field ids (guest_session_guest_name, etc.), not
# translated label text — the entry form's initial locale comes from
# whatever Accept-Language the headless browser happens to send, which this
# suite doesn't control and shouldn't need to, per test-machine environment.
# The language <select>'s options are the one exception: their labels are
# each language's own native name (GuestLocaleHelper::LOCALE_NAMES),
# hardcoded regardless of the page's current locale, so selecting "العربية"
# by that literal text is itself locale-independent.
class GuestEntryTest < ApplicationSystemTestCase
  test "a guest fills the form, chooses Arabic, and reaches the chat on a right-to-left page" do
    visit hotel_landing_path(hotels(:stari_grad).slug)

    fill_in "guest_session_guest_name", with: "Layla Guest"
    fill_in "guest_session_room_number", with: "301"
    select "العربية", from: "guest_session_locale"
    check "guest_session_consent"
    find("#guest-submit").click

    assert_current_path guest_chat_path
    assert_text "Layla Guest"
    assert_selector "html[dir='rtl']"
  end

  # Precondition set up directly (a real GuestSession row + a browser cookie
  # for it), not by driving the form through the browser a second time — the
  # behaviour under test here is the landing page's own redirect logic, not
  # entry-form submission again.
  test "revisiting the landing page with an existing guest cookie skips straight to the chat" do
    hotel = hotels(:stari_grad)
    raw_token = SecureRandom.urlsafe_base64(32)

    with_tenant(hotel) do
      hotel.guest_sessions.create!(
        guest_name: "Returning Guest", room: rooms(:stari_301), locale: "en",
        privacy_accepted_at: Time.current, expires_at: 7.days.from_now,
        token_digest: GuestSession.digest(raw_token)
      )
    end

    # A cookie can only be set for a domain the browser has already loaded —
    # this first visit is purely to establish that domain before injecting
    # the signed cookie a real sign-up would have set via Set-Cookie.
    visit hotel_landing_path(hotel.slug)
    page.driver.browser.manage.add_cookie(name: "hospello_guest", value: guest_signed_cookie_value(raw_token), path: "/")

    visit hotel_landing_path(hotel.slug)

    assert_current_path guest_chat_path
    assert_text "Returning Guest"
  end

  test "an invalid room number keeps the guest on the form with a visible error" do
    visit hotel_landing_path(hotels(:stari_grad).slug)

    fill_in "guest_session_guest_name", with: "Bad Room Guest"
    fill_in "guest_session_room_number", with: "does-not-exist"
    check "guest_session_consent"
    find("#guest-submit").click

    assert_current_path hotel_landing_path(hotels(:stari_grad).slug)
    assert_selector "#form-errors"
    assert_text(/room/i)
  end

  private
    # Builds the exact signed cookie value Guest::EntriesController#issue_guest_cookie
    # would have set via `cookies.signed[:hospello_guest] = raw_token` — same
    # technique as GuestSignInTestHelper#sign_in_guest (test/test_helper.rb),
    # but written through Selenium's own cookie API since a system test
    # drives a real browser, not Rails' mocked integration session.
    def guest_signed_cookie_value(raw_token)
      jar = ActionDispatch::TestRequest.create.cookie_jar
      jar.signed[:hospello_guest] = raw_token
      jar[:hospello_guest]
    end
end
