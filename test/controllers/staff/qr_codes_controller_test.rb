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

  # Review round 1, minor: asserting only that "[lang='xx']" exists is hollow —
  # it passes for an empty div just as well as for real copy. Each block is
  # pinned to its actual headline and instruction text, so replacing the copy
  # with a placeholder (or losing a language's instruction line while leaving
  # its headline) fails here.
  test "the print view carries a headline and instruction in each guest language" do
    sign_in users(:stari_admin)
    hotels(:stari_grad).update!(plan: :service)

    get print_staff_qr_code_path

    assert_response :success

    assert_select "[lang='bs']" do
      assert_select "p", text: "Trebate nešto? Samo pitajte.", count: 1
      assert_select "p", text: "Skenirajte kod i pišite recepciji u bilo koje doba.", count: 1
    end

    assert_select "[lang='en']" do
      assert_select "p", text: "Need anything? Just ask.", count: 1
      assert_select "p", text: "Scan the code to chat with our front desk anytime.", count: 1
    end

    assert_select "[lang='ar']" do
      assert_select "p", text: "هل تحتاج إلى شيء؟ فقط اسأل.", count: 1
      assert_select "p", text: "امسح الرمز للتواصل مع الاستقبال في أي وقت.", count: 1
    end
  end

  # German was dropped from the card in 2026-08: a fourth block earns its space
  # only if the hotel actually sees those guests, and a crowded card is read by
  # nobody. This is asserted rather than simply deleted so that re-adding a
  # language is a deliberate decision with a test to change, not a silent creep
  # back to four.
  #
  # It does not narrow the chat itself — the concierge still answers a guest who
  # writes in German, which is what the second assertion is here to state.
  test "the card is printed in three languages, not four" do
    sign_in users(:stari_admin)

    get print_staff_qr_code_path

    assert_select "#language-lines > div", count: 3
    assert_select "[lang='de']", count: 0
    assert_includes GuestLocaleHelper::SUPPORTED_LOCALES, "de",
      "dropping German from the printed card must not drop it from the chat"
  end

  # An Essentials hotel's QR code does not reach the front desk, so a card
  # promising a chat with reception would be a promise the product does not
  # keep — printed, and left in a room where nobody can correct it.
  test "an Essentials hotel's card invites questions, not requests" do
    sign_in users(:stari_admin)
    hotels(:stari_grad).update!(plan: :essentials)

    get print_staff_qr_code_path

    assert_response :success

    assert_select "[lang='en']" do
      assert_select "p", text: "Have a question? Just ask.", count: 1
      assert_select "p", text: "Scan the code to ask anything about the hotel.", count: 1
    end

    assert_select "[lang='bs']" do
      assert_select "p", text: "Imate pitanje? Samo pitajte.", count: 1
    end

    # The words that would be the lie.
    assert_select "#language-lines", text: /front desk/, count: 0
    assert_select "#language-lines", text: /recepciji/, count: 0
  end

  # The number is how a guest on Essentials actually reaches a person, so it
  # must survive on the plan that depends on it most.
  test "the reception number is still printed on an Essentials card" do
    sign_in users(:stari_admin)
    hotels(:stari_grad).update!(plan: :essentials, contact_phone: "+387 33 000 000")

    get print_staff_qr_code_path

    assert_select "#reception-phone", text: /\+387 33 000 000/
  end

  test "the Arabic line renders right-to-left" do
    sign_in users(:stari_admin)

    get print_staff_qr_code_path

    assert_response :success
    assert_select "[lang='ar'][dir='rtl']", count: 1
  end

  # Review round 1, IMPORTANT 3: dir="rtl" alone fixes character/bidi
  # ordering but not alignment — text-align inherits, and a physical
  # "text-left" on the container left the Arabic paragraph hugging the left
  # edge of the card, visibly wrong to an Arabic reader even though the
  # attribute-level test above passed. This pins the actual fix (a logical,
  # direction-aware alignment utility on the container, not a physical
  # left/right one) at the markup level; the system test below additionally
  # checks the real computed style in a browser, which is the only way to
  # catch a regression that swaps text-start for some other-looking-plausible
  # class that isn't actually direction-aware.
  test "the language lines use a direction-aware alignment, not a hardcoded left alignment" do
    sign_in users(:stari_admin)

    get print_staff_qr_code_path

    assert_response :success
    assert_select "#language-lines.text-start", count: 1
    assert_select "#language-lines.text-left", count: 0
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
    # Both fixture users read the staff workspace in Bosnian — see
    # fixtures — so the nav label is staff.nav.qr_code's "QR kod"
    # (config/locales/staff.bs.yml).
    assert_select "nav a[href=?]", staff_qr_code_path, text: "QR kod", count: 1
  end

  test "the staff nav offers a working QR code link to plain staff too — read-only, not admin-only" do
    sign_in users(:stari_staff)

    get staff_root_path

    assert_response :success
    # Both fixture users read the staff workspace in Bosnian — see
    # fixtures — so the nav label is staff.nav.qr_code's "QR kod"
    # (config/locales/staff.bs.yml).
    assert_select "nav a[href=?]", staff_qr_code_path, text: "QR kod", count: 1
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

  # config/environments/production.rb resolves ENV["APP_HOST"] into
  # config.x.app_host exactly once, at boot (see AppHost) — that boot never
  # runs under RAILS_ENV=test, so these two tests simulate its result
  # directly (setting config.x.app_host) rather than ENV, and prove the
  # controller picks the right one of "config.x.app_host" vs "the request"
  # based on environment, not that AppHost's own normalization works (that's
  # test/services/app_host_test.rb's job, tested with no Rails boot at all).
  test "outside production the host comes from the request, even if config.x.app_host is set" do
    original_app_host = Rails.application.config.x.app_host
    Rails.application.config.x.app_host = "wrong-host.example"
    sign_in users(:stari_admin)

    get staff_qr_code_path

    assert_response :success
    assert_select "#qr-url", text: "https://www.example.com/h/stari-grad"
  ensure
    Rails.application.config.x.app_host = original_app_host
  end

  test "in production the host comes from config.x.app_host (resolved once at boot), never the request host" do
    original_app_host = Rails.application.config.x.app_host
    original_rails_env = Rails.env
    Rails.application.config.x.app_host = "hospello.app"
    Rails.env = "production"
    sign_in users(:stari_admin)

    get staff_qr_code_path

    assert_response :success
    assert_select "#qr-url", text: "https://hospello.app/h/stari-grad"
  ensure
    Rails.application.config.x.app_host = original_app_host
    Rails.env = original_rails_env
  end
end
