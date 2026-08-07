require "application_system_test_case"

# Acceptance scenario 2's headline moment: a hotel admin downloads the
# hotel's reusable QR code. Kept to one short, focused test per the house
# rules — the print sheet's four-language content and the powered-by toggle
# are already covered at the controller level
# (test/controllers/staff/qr_codes_controller_test.rb); this test only
# proves the nav link is wired to a real page in a real browser and that the
# download affordances are actually on it.
class QrDownloadTest < ApplicationSystemTestCase
  test "a hotel admin reaches the QR code page from the nav and finds the download links" do
    sign_in_as users(:stari_admin), password: "password123"

    visit staff_root_path
    click_on "QR code"

    assert_current_path staff_qr_code_path
    assert_match %r{\Ahttps://.+/h/stari-grad\z}, find("#qr-url").text
    assert_selector "a[href='#{staff_qr_code_path(format: :svg)}']", text: "Download SVG"
    assert_selector "a[href='#{staff_qr_code_path(format: :png)}']", text: "Download PNG"
  end

  private
    # `click_on` returns when the click is dispatched, not when the resulting
    # page has loaded — asserting on the destination makes the click and its
    # navigation a single step, matching the other system tests in this project.
    def sign_in_as(user, password:)
      visit root_url
      fill_in "email_address", with: user.email_address
      fill_in "password", with: password
      click_on "Sign in"
      assert_text "Signed in as #{user.name}"
    end
end
