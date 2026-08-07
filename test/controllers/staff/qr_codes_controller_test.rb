require "test_helper"

# There is no id anywhere in these routes — Staff::QrCodesController always
# renders Current.hotel's own code, the same "no id in the path" shape as
# Staff::HotelSettingsController — so unlike rooms/departments/categories/
# users, there is nothing to add to test/tenancy/cross_tenant_access_test.rb:
# a hotel A admin requesting /staff/qr_code can only ever see hotel A's code.
class Staff::QrCodesControllerTest < ActionDispatch::IntegrationTest
  test "a hotel admin sees the show page with the hotel's guest URL" do
    sign_in users(:stari_admin)

    get staff_qr_code_path

    assert_response :success
    assert_select "#qr-url", text: "https://www.example.com/h/stari-grad"
  end

  test "a hotel admin from a different hotel sees THEIR OWN hotel's QR, not stari grad's" do
    sign_in users(:vrelo_admin)

    get staff_qr_code_path

    assert_response :success
    assert_select "#qr-url", text: "https://www.example.com/h/vrelo-bosne"
  end

  test "a plain staff user may also view the QR page — this is not admin-only" do
    sign_in users(:stari_staff)

    get staff_qr_code_path

    assert_response :success
    assert_select "#qr-url", text: "https://www.example.com/h/stari-grad"
  end

  test "a plain staff user may also view the print sheet" do
    sign_in users(:stari_staff)

    get print_staff_qr_code_path

    assert_response :success
  end

  test "the SVG download responds 200 with image/svg+xml and a slug-bearing filename" do
    sign_in users(:stari_admin)

    get staff_qr_code_path(format: :svg)

    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_match(/stari-grad/, response.headers["Content-Disposition"])
    assert_includes response.body, "<svg"
  end

  test "the PNG download responds 200 with image/png and a slug-bearing filename" do
    sign_in users(:stari_admin)

    get staff_qr_code_path(format: :png)

    assert_response :success
    assert_equal "image/png", response.media_type
    assert_match(/stari-grad/, response.headers["Content-Disposition"])
    assert_equal "\x89PNG\r\n\x1a\n".b, response.body.byteslice(0, 8)
  end

  test "the print view contains a short headline and instruction in all four guest languages" do
    sign_in users(:stari_admin)

    get print_staff_qr_code_path

    assert_response :success
    assert_select "[lang='bs']", count: 1
    assert_select "[lang='en']", count: 1
    assert_select "[lang='de']", count: 1
    assert_select "[lang='ar']", count: 1
  end

  test "the Arabic line renders right-to-left" do
    sign_in users(:stari_admin)

    get print_staff_qr_code_path

    assert_response :success
    assert_select "[lang='ar'][dir='rtl']", count: 1
  end

  test "the print view shows the hotel's reception phone number" do
    sign_in users(:stari_admin)

    get print_staff_qr_code_path

    assert_response :success
    assert_select "#reception-phone", text: /#{Regexp.escape(hotels(:stari_grad).contact_phone)}/
  end

  test "Powered by Hospello appears when the hotel has it enabled" do
    hotel = hotels(:stari_grad)
    assert hotel.powered_by_visible?, "fixture must start with powered_by_visible true for this test to mean anything"
    sign_in users(:stari_admin)

    get print_staff_qr_code_path

    assert_response :success
    assert_select "#powered-by", text: "Powered by Hospello"
  end

  test "Powered by Hospello is absent when the hotel has it disabled" do
    hotels(:stari_grad).update!(powered_by_visible: false)
    sign_in users(:stari_admin)

    get print_staff_qr_code_path

    assert_response :success
    assert_select "#powered-by", count: 0
  end

  test "the staff nav offers a working QR code link to a hotel admin" do
    sign_in users(:stari_admin)

    get staff_root_path

    assert_response :success
    assert_select "nav a[href=?]", staff_qr_code_path, text: "QR code", count: 1
  end

  test "the staff nav offers a working QR code link to plain staff too — read-only, not admin-only" do
    sign_in users(:stari_staff)

    get staff_root_path

    assert_response :success
    assert_select "nav a[href=?]", staff_qr_code_path, text: "QR code", count: 1
  end

  test "a signed-out user is redirected to sign-in" do
    get staff_qr_code_path
    assert_redirected_to new_session_path

    get print_staff_qr_code_path
    assert_redirected_to new_session_path
  end

  test "a platform admin cannot reach the QR routes" do
    sign_in users(:platform)

    get staff_qr_code_path
    assert_response :forbidden

    get print_staff_qr_code_path
    assert_response :forbidden
  end

  test "outside production the host comes from the request, not ENV[\"APP_HOST\"]" do
    original_app_host = ENV["APP_HOST"]
    ENV["APP_HOST"] = "wrong-host.example"
    sign_in users(:stari_admin)

    get staff_qr_code_path

    assert_response :success
    assert_select "#qr-url", text: "https://www.example.com/h/stari-grad"
  ensure
    ENV["APP_HOST"] = original_app_host
  end

  test "in production the host comes from ENV[\"APP_HOST\"], never the request host" do
    original_app_host = ENV["APP_HOST"]
    original_rails_env = Rails.env
    ENV["APP_HOST"] = "hospello.app"
    Rails.env = "production"
    sign_in users(:stari_admin)

    get staff_qr_code_path

    assert_response :success
    assert_select "#qr-url", text: "https://hospello.app/h/stari-grad"
  ensure
    ENV["APP_HOST"] = original_app_host
    Rails.env = original_rails_env
  end
end
