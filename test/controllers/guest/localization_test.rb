require "test_helper"

# Review round 1 findings CRITICAL 2 and IMPORTANT 3-7: every one of these
# assertions was previously unprotected — deleting config/locales/guest.ar.yml
# entirely, removing the emergency notice or the privacy notice from the
# view, forcing "Powered by Hospello" always-on, or hardcoding the language
# select to "en" all left the full suite green. Expected strings below are
# hardcoded literals copied from the locale files, not a second call to
# I18n.t against the same file under test — calling I18n.t here would read
# the very file being verified and could pass vacuously off its own
# fallback (config.i18n.fallbacks = true silently substitutes English for a
# missing key).
class Guest::LocalizationTest < ActionDispatch::IntegrationTest
  NOT_EMERGENCY_NOTICE = {
    "bs" => "nije namijenjen za hitne slučajeve",
    "en" => "is not for emergencies",
    "de" => "ist nicht für Notfälle gedacht",
    "ar" => "ليست مخصصة لحالات الطوارئ"
  }.freeze

  PRIVACY_PENDING_REVIEW_MARKER = {
    "bs" => "NACRT",
    "en" => "DRAFT",
    "de" => "ENTWURF",
    "ar" => "مسودة"
  }.freeze

  SUBMIT_LABEL = {
    "bs" => "Započni razgovor",
    "en" => "Start chat",
    "de" => "Chat starten",
    "ar" => "ابدأ المحادثة"
  }.freeze

  test "the not-an-emergency notice renders its real translated copy in every supported language" do
    NOT_EMERGENCY_NOTICE.each do |locale, expected_substring|
      get hotel_landing_path(hotels(:stari_grad).slug), headers: { "Accept-Language" => locale }

      assert_response :success
      assert_select "#not-emergency-notice", text: /#{Regexp.escape(expected_substring)}/,
        count: 1
    end
  end

  test "the privacy notice's pending-legal-review marker renders in every supported language" do
    PRIVACY_PENDING_REVIEW_MARKER.each do |locale, expected_substring|
      get hotel_landing_path(hotels(:stari_grad).slug), headers: { "Accept-Language" => locale }

      assert_response :success
      assert_select "#privacy-notice", text: /#{Regexp.escape(expected_substring)}/,
        count: 1
    end
  end

  test "the submit button renders its real translated label in every supported language" do
    SUBMIT_LABEL.each do |locale, expected_label|
      get hotel_landing_path(hotels(:stari_grad).slug), headers: { "Accept-Language" => locale }

      assert_response :success
      assert_select "#guest-submit[value=?]", expected_label
    end
  end

  # IMPORTANT 4 (review round 1): a spec-required safety line, previously
  # removable from the view with the full suite staying green.
  test "the not-an-emergency notice is present at all and says what to do instead" do
    get hotel_landing_path(hotels(:stari_grad).slug)

    assert_response :success
    assert_select "#not-emergency-notice", text: /call reception/i
  end

  # IMPORTANT 5 (review round 1): both the notice's presence and its
  # pending-review marker were previously removable with the suite staying
  # green.
  test "the privacy notice is present, with its title, body, and pending-review marker" do
    get hotel_landing_path(hotels(:stari_grad).slug)

    assert_response :success
    assert_select "#privacy-notice summary", text: "Privacy notice"
    assert_select "#privacy-notice", text: /DRAFT/
    assert_select "#privacy-notice", text: /your name, room number, and messages/
  end

  # IMPORTANT 6 (review round 1): mirrors the staff-side pattern
  # (test/controllers/staff/qr_codes_controller_test.rb "Powered by
  # Hospello appears/is absent") — assert the fixture's starting state
  # first so this can't pass vacuously, then flip the flag and re-assert.
  test "Powered by Hospello appears on the landing page when the hotel has it enabled" do
    hotel = hotels(:stari_grad)
    assert hotel.powered_by_visible?, "fixture must start with powered_by_visible true for this test to mean anything"

    get hotel_landing_path(hotel.slug)

    assert_response :success
    assert_select "#powered-by-hospello", text: "Powered by Hospello"
  end

  test "Powered by Hospello is absent from the landing page when the hotel has it disabled" do
    hotel = hotels(:stari_grad)
    hotel.update!(powered_by_visible: false)

    get hotel_landing_path(hotel.slug)

    assert_response :success
    assert_select "#powered-by-hospello", count: 0
  end

  # IMPORTANT 7 (review round 1): GuestLocaleHelper.detect is well tested in
  # isolation (test/helpers/guest_locale_helper_test.rb) — what was missing
  # is proof the landing page's language <select> actually uses it to
  # preselect an option, rather than always defaulting to English.
  test "the language select is preselected from the Accept-Language header" do
    get hotel_landing_path(hotels(:stari_grad).slug), headers: { "Accept-Language" => "de-DE,de;q=0.9,en;q=0.5" }

    assert_response :success
    assert_select "#guest_session_locale option[value='de'][selected]", count: 1
    assert_select "#guest_session_locale option[selected]", count: 1
  end

  test "a different Accept-Language header preselects a different option" do
    get hotel_landing_path(hotels(:stari_grad).slug), headers: { "Accept-Language" => "ar" }

    assert_response :success
    assert_select "#guest_session_locale option[value='ar'][selected]", count: 1
    assert_select "#guest_session_locale option[value='de'][selected]", count: 0
  end

  # IMPORTANT 3 (review round 1): dir="rtl" alone reorders characters/bidi,
  # not alignment — this pins the markup-level half of the fix (a logical,
  # direction-aware alignment utility, not a hardcoded physical one) at the
  # controller level, mirroring test/controllers/staff/qr_codes_controller_test.rb's
  # "#language-lines.text-start" / ".text-left count 0" pattern exactly.
  # test/system/guest_entry_test.rb adds the real-geometry half, mirroring
  # test/system/qr_download_test.rb.
  test "the not-an-emergency notice uses a direction-aware alignment, not a hardcoded left alignment" do
    get hotel_landing_path(hotels(:stari_grad).slug)

    assert_response :success
    assert_select "#not-emergency-notice.text-start", count: 1
    assert_select "#not-emergency-notice.text-left", count: 0
  end
end
