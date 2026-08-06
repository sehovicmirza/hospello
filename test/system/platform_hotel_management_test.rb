require "application_system_test_case"

class PlatformHotelManagementTest < ApplicationSystemTestCase
  test "a platform admin creates two hotels, gives one its first admin, and suspends the other" do
    sign_in_as users(:platform), password: "password123"

    create_hotel(name: "Hotel Two Rivers", slug: "two-rivers", staff_language: "Bosnian", escalation_email: "ops@two-rivers.example")
    assert_text "Hotel Two Rivers created."

    create_hotel(name: "Hotel Lakeview", slug: "lakeview", staff_language: "English", escalation_email: "ops@lakeview.example")
    assert_text "Hotel Lakeview created."

    visit platform_hotels_path
    click_on "Hotel Two Rivers"
    click_on "Create first admin"

    fill_in "Name", with: "Amra Selimović"
    fill_in "Email address", with: "amra@two-rivers.example"
    fill_in "Password", with: "password123"
    fill_in "Confirm password", with: "password123"
    click_on "Create admin"

    assert_text "Amra Selimović created as the admin for Hotel Two Rivers."

    visit platform_hotels_path
    click_on "Hotel Lakeview"
    click_on "Suspend hotel"

    assert_text "Hotel Lakeview suspended."

    visit platform_hotels_path

    within "##{ActionView::RecordIdentifier.dom_id(Hotel.find_by!(slug: 'two-rivers'))}" do
      assert_text "Active"
      assert_text "Yes"
    end

    within "##{ActionView::RecordIdentifier.dom_id(Hotel.find_by!(slug: 'lakeview'))}" do
      assert_text "Suspended"
      assert_text "Not yet"
    end
  end

  private
    def sign_in_as(user, password:)
      visit root_url
      fill_in "email_address", with: user.email_address
      fill_in "password", with: password
      click_on "Sign in"
    end

    # Reaching the form is plumbing already proven by "New hotel" being a
    # plain link to this same path; a direct visit keeps the part of the test
    # that matters — filling in and submitting the real form — free of
    # unrelated navigation steps.
    def create_hotel(name:, slug:, staff_language:, escalation_email:)
      visit new_platform_hotel_path
      fill_in "Name", with: name
      fill_in "Slug", with: slug
      fill_in "Time zone", with: "Europe/Sarajevo"
      select staff_language, from: "Staff language"
      fill_in "Escalation email", with: escalation_email
      click_on "Create hotel"
    end
end
