require "application_system_test_case"

class AuthenticationTest < ApplicationSystemTestCase
  test "a staff user signs in with email and password" do
    sign_in_as users(:stari_staff), password: "password123"

    # stari_staff reads the staff workspace in Bosnian — see
    # test/fixtures/users.yml — staff.layout.signed_in_as_html
    # (config/locales/staff.bs.yml), pasted literally.
    assert_text "Prijavljeni ste kao #{users(:stari_staff).name}"
  end

  test "a wrong password shows an error and does not sign in" do
    sign_in_as users(:stari_staff), password: "wrong-password"

    assert_text "Try another email address or password."
    assert_no_text "Signed in as"
  end

  test "a suspended hotel's staff user is refused" do
    hotels(:vrelo).suspended!

    sign_in_as users(:vrelo_staff), password: "password123"

    assert_text "This account is not active."
    assert_no_text "Signed in as"
  end

  private
    def sign_in_as(user, password:)
      visit root_url
      fill_in "email_address", with: user.email_address
      fill_in "password", with: password
      click_on "Sign in"
    end
end
