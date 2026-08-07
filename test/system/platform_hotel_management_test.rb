require "application_system_test_case"

# One flow per test, deliberately.
#
# These began as a single test that created two hotels, added an admin and
# suspended a hotel in one browser session. It failed constantly: after the
# first form submit, later clicks and keystrokes in that session were silently
# dropped — fields stayed empty and forms never submitted, while the same
# requests were provably correct at the controller level. Splitting the flows
# keeps each test inside the interaction budget a session reliably survives,
# and it means a failure names the flow that broke instead of pointing at step
# nine of nine. Preconditions are set up directly; only the behaviour under
# test goes through the browser.
class PlatformHotelManagementTest < ApplicationSystemTestCase
  setup { sign_in_as users(:platform), password: "password123" }

  test "a platform admin creates a hotel" do
    visit new_platform_hotel_path

    fill_in "Name", with: "Hotel Two Rivers"
    fill_in "Slug", with: "two-rivers"
    select "Bosnian", from: "Staff language"
    click_on "Create hotel"

    assert_text "Hotel Two Rivers created."

    hotel = Hotel.find_by!(slug: "two-rivers")
    assert_equal "bs", hotel.staff_locale
    assert hotel.active?
  end

  test "a platform admin gives a hotel its first admin" do
    visit new_platform_hotel_hotel_admin_path(hotels(:vrelo))

    fill_in "Name", with: "Amra Selimović"
    fill_in "Email address", with: "amra@vrelo.example"
    fill_in "Password", with: "password123"
    fill_in "Confirm password", with: "password123"
    click_on "Create admin"

    assert_text "Amra Selimović created as the admin for #{hotels(:vrelo).name}."

    admin = User.find_by!(email_address: "amra@vrelo.example")
    assert admin.hotel_admin?
    assert_equal hotels(:vrelo), admin.hotel
  end

  test "a platform admin suspends and reactivates a hotel" do
    visit platform_hotel_path(hotels(:stari_grad))

    click_on "Suspend hotel"
    assert_text "#{hotels(:stari_grad).name} suspended."
    assert hotels(:stari_grad).reload.suspended?

    click_on "Reactivate hotel"
    assert_text "#{hotels(:stari_grad).name} reactivated."
    assert hotels(:stari_grad).reload.active?
  end

  test "the hotel list shows each hotel's readiness at a glance" do
    hotels(:vrelo).suspended!

    visit platform_hotels_path

    within "##{ActionView::RecordIdentifier.dom_id(hotels(:stari_grad))}" do
      assert_text "Active"
      assert_text "Yes" # stari_grad has a hotel_admin fixture
    end

    within "##{ActionView::RecordIdentifier.dom_id(hotels(:vrelo))}" do
      assert_text "Suspended"
    end
  end

  private
    # `click_on` returns when the click is dispatched, not when the page it
    # triggers has loaded. Navigating again before the sign-in response lands
    # leaves the session cookie unset, and the next page is a redirect back to
    # this form. Asserting on the destination makes the click and its
    # navigation a single step.
    def sign_in_as(user, password:)
      visit root_url
      fill_in "email_address", with: user.email_address
      fill_in "password", with: password
      click_on "Sign in"
      assert_text "Signed in as #{user.name}"
    end
end
