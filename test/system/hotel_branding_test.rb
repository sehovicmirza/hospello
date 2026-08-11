require "application_system_test_case"

class HotelBrandingTest < ApplicationSystemTestCase
  test "a hotel admin updates the hotel's branding and it persists" do
    sign_in_as users(:stari_admin), password: "password123"

    visit edit_staff_hotel_settings_path
    # stari_admin reads the staff workspace in Bosnian — see
    # test/fixtures/users.yml — so these are staff.hotel_settings.edit's
    # Bosnian labels (config/locales/staff.bs.yml). "Logo" reads the same
    # in both locale files.
    fill_in "Primarna boja", with: "#334455"
    fill_in "Ime asistenta", with: "Selma"
    attach_file "Logo", file_fixture("logo.png")
    click_on "Sačuvaj izmjene"

    assert_text "Hotel settings updated."

    hotel = hotels(:stari_grad).reload
    assert_equal "#334455", hotel.primary_color
    assert_equal "Selma", hotel.concierge_name
    assert hotel.logo.attached?
  end

  private
    # `click_on` returns when the click is dispatched, not when the resulting
    # page has loaded — asserting on the destination makes the click and its
    # navigation a single step, matching the other system tests in this project.
    #
    # stari_admin reads the staff workspace in Bosnian — see
    # test/fixtures/users.yml — so this is staff.layout.signed_in_as_html's
    # Bosnian text (config/locales/staff.bs.yml), pasted literally.
    def sign_in_as(user, password:)
      visit root_url
      fill_in "email_address", with: user.email_address
      fill_in "password", with: password
      click_on "Sign in"
      assert_text "Prijavljeni ste kao #{user.name}"
    end
end
