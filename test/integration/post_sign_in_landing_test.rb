require "test_helper"

# Signing in used to leave every role on the application root, which renders
# the sign-in page's shell: a header reading "Signed in as …" above an empty
# page with no links. The product looked broken immediately after login, so
# these pin where each role actually starts.
class PostSignInLandingTest < ActionDispatch::IntegrationTest
  test "a platform admin lands on the hotel list" do
    sign_in_through_the_form users(:platform)
    assert_equal platform_hotels_path, path_after_redirects
  end

  test "a hotel admin lands on the staff dashboard" do
    sign_in_through_the_form users(:stari_admin)
    assert_equal staff_root_path, path_after_redirects
  end

  test "a receptionist lands on the staff dashboard" do
    sign_in_through_the_form users(:stari_staff)
    assert_equal staff_root_path, path_after_redirects
  end

  test "visiting the root while already signed in goes to your own namespace" do
    sign_in users(:platform)

    get root_path

    assert_redirected_to platform_hotels_url
  end

  test "the root still shows the sign-in form when signed out" do
    get root_path

    assert_response :success
    assert_select "input[name='password']"
  end

  test "a requested page is still honoured over the role's home" do
    get new_platform_hotel_path
    assert_redirected_to new_session_path

    post session_path, params: { email_address: users(:platform).email_address, password: "password123" }

    assert_redirected_to new_platform_hotel_url
  end

  private
    def sign_in_through_the_form(user)
      post session_path, params: { email_address: user.email_address, password: "password123" }
    end

    def path_after_redirects
      follow_redirect! while response.redirect?
      request.path
    end
end
