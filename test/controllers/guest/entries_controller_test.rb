require "test_helper"

# GuestSession is TenantScoped, so a bare GuestSession.count has no ambient
# tenant at the point these assert_(no_)difference blocks are evaluated and
# would raise ActsAsTenant::Errors::NoTenantSet under require_tenant = true.
# `.unscoped` bypasses acts_as_tenant's default_scope entirely — a plain
# ActiveRecord mechanism, unrelated to the ActsAsTenant.without_tenant family
# test/tenancy/without_tenant_grep_test.rb polices, and fine to use freely in
# tests (see test/controllers/staff/rooms_controller_test.rb's header for the
# same reasoning) — to get a true cross-tenant row count.
class Guest::EntriesControllerTest < ActionDispatch::IntegrationTest
  test "GET /h/:slug renders the landing page with the hotel's name, welcome message, and contact phone, no session required" do
    get hotel_landing_path(hotels(:stari_grad).slug)

    assert_response :success
    assert_select "#hotel-name", text: "Hotel Stari Grad"
    assert_select "#welcome-message", text: "Dobrodošli u Hotel Stari Grad!"
    assert_select "#contact-phone a[href='tel:+38733000000']"
  end

  test "GET /h/nonexistent renders 404" do
    get hotel_landing_path("nonexistent-hotel")

    assert_response :not_found
  end

  test "GET /h/:slug for a suspended hotel renders a not-available page, not the chat entry form" do
    hotel = hotels(:stari_grad)
    hotel.update!(status: :suspended)

    get hotel_landing_path(hotel.slug)

    assert_response :success
    assert_select "form#new_guest_session", count: 0
    assert_select "#hotel-unavailable"
  end

  test "posting to a suspended hotel's landing page is refused too, not just the GET" do
    hotel = hotels(:stari_grad)
    hotel.update!(status: :suspended)

    assert_no_difference -> { GuestSession.unscoped.count } do
      post hotel_landing_path(hotel.slug), params: {
        guest_session: { guest_name: "Guest", room_number: "301", locale: "en", consent: "1" }
      }
    end

    assert_select "#hotel-unavailable"
  end

  test "posting a valid name, room number, locale, and consent creates a GuestSession, sets the cookie, and redirects to the chat" do
    hotel = hotels(:stari_grad)

    assert_difference -> { GuestSession.unscoped.count }, 1 do
      post hotel_landing_path(hotel.slug), params: {
        guest_session: { guest_name: "Aisha Guest", room_number: " 301 ", locale: "ar", consent: "1" }
      }
    end

    assert_redirected_to guest_chat_path

    session = GuestSession.unscoped.order(:created_at).last
    assert_equal hotel.id, session.hotel_id
    assert_equal "Aisha Guest", session.guest_name
    assert_equal rooms(:stari_301).id, session.room_id
    assert_equal "ar", session.locale
    assert session.unverified?
    assert_not_nil session.privacy_accepted_at
    assert_not_nil session.token_digest

    raw_token = read_signed_cookie(:hospello_guest)
    assert_not_nil raw_token
    assert_equal GuestSession.digest(raw_token), session.token_digest
  end

  test "posting without a phone number succeeds — phone is optional (acceptance scenario 3)" do
    hotel = hotels(:stari_grad)

    assert_difference -> { GuestSession.unscoped.count }, 1 do
      post hotel_landing_path(hotel.slug), params: {
        guest_session: { guest_name: "No Phone Guest", room_number: "301", locale: "en", consent: "1" }
      }
    end

    assert_redirected_to guest_chat_path
    assert_nil GuestSession.unscoped.order(:created_at).last.phone_e164
  end

  test "posting a room number that is not in the hotel's active room list re-renders the form with a friendly error and creates nothing" do
    hotel = hotels(:stari_grad)

    assert_no_difference -> { GuestSession.unscoped.count } do
      post hotel_landing_path(hotel.slug), params: {
        guest_session: { guest_name: "Bad Room Guest", room_number: "does-not-exist", locale: "en", consent: "1" }
      }
    end

    assert_response :unprocessable_content
    assert_select "form#new_guest_session"
    assert_select "#form-errors", text: /room/i
  end

  test "posting an inactive room's number is refused, the same as an unknown one" do
    hotel = hotels(:stari_grad)

    assert_no_difference -> { GuestSession.unscoped.count } do
      post hotel_landing_path(hotel.slug), params: {
        guest_session: { guest_name: "Inactive Room Guest", room_number: rooms(:stari_309).number, locale: "en", consent: "1" }
      }
    end

    assert_response :unprocessable_content
    assert_select "#form-errors", text: /room/i
  end

  test "posting without checking the consent checkbox re-renders with an error and creates nothing" do
    hotel = hotels(:stari_grad)

    assert_no_difference -> { GuestSession.unscoped.count } do
      post hotel_landing_path(hotel.slug), params: {
        guest_session: { guest_name: "No Consent Guest", room_number: "301", locale: "en" }
      }
    end

    assert_response :unprocessable_content
    assert_select "form#new_guest_session"
    assert_select "#form-errors", text: /privacy|consent/i
  end

  test "the created session is unverified even if the request tries to set identity_status — mass assignment is impossible" do
    hotel = hotels(:stari_grad)

    post hotel_landing_path(hotel.slug), params: {
      guest_session: {
        guest_name: "Sneaky Guest", room_number: "301", locale: "en", consent: "1",
        identity_status: "staff_verified"
      }
    }

    assert_redirected_to guest_chat_path
    session = GuestSession.unscoped.order(:created_at).last
    assert session.unverified?
    assert_not session.staff_verified?
  end

  test "a request for hotel A's landing page can never create a session on hotel B" do
    stari = hotels(:stari_grad)
    vrelo = hotels(:vrelo)

    post hotel_landing_path(stari.slug), params: {
      guest_session: {
        guest_name: "Cross Tenant Guest", room_number: "301", locale: "en", consent: "1",
        hotel_id: vrelo.id
      }
    }

    assert_redirected_to guest_chat_path
    session = GuestSession.unscoped.order(:created_at).last
    assert_equal stari.id, session.hotel_id
    assert_not_equal vrelo.id, session.hotel_id
  end

  # The persistence requirement (brief Step 6): a returning guest who
  # re-scans/re-visits the same hotel's landing URL must not have to
  # re-enter anything.
  test "revisiting the landing page with a valid guest cookie for this hotel redirects straight to the chat" do
    sign_in_guest("stari-grad-fixture-guest-token")

    get hotel_landing_path(hotels(:stari_grad).slug)

    assert_redirected_to guest_chat_path
  end

  test "an existing guest cookie for a different hotel does not skip that hotel's own entry form" do
    sign_in_guest("stari-grad-fixture-guest-token")

    get hotel_landing_path(hotels(:vrelo).slug)

    assert_response :success
    assert_select "form#new_guest_session"
  end

  # --- The WhatsApp door (Slice 6 Task 4) --------------------------------------
  #
  # The hotel's other front door, offered on the same page as the QR chat.

  test "a hotel with a live WhatsApp number offers it as a way in" do
    get hotel_landing_path(hotels(:stari_grad).slug)

    assert_response :success
    # Digits only and no leading + — wa.me silently produces a dead link for
    # a URL-encoded plus, which is the kind of break nobody notices until a
    # guest reports it.
    assert_select "#whatsapp-cta[href^=?]", "https://wa.me/38761100100?text="
  end

  # A channel that exists but is `pending` or `disabled` is a number nobody is
  # answering. A button leading there is worse than no button: the guest sends
  # a message into silence and concludes the hotel is ignoring them.
  test "a number that is not live yet is not offered at all" do
    assert with_tenant(hotels(:vrelo)) { whatsapp_channels(:vrelo_whatsapp).pending? },
      "fixture drift: vrelo's channel is meant to be pending"

    get hotel_landing_path(hotels(:vrelo).slug)

    assert_response :success
    assert_select "#whatsapp-cta", count: 0
  end

  test "a hotel with no WhatsApp channel at all renders the page normally" do
    with_tenant(hotels(:vrelo)) { whatsapp_channels(:vrelo_whatsapp).destroy! }

    get hotel_landing_path(hotels(:vrelo).slug)

    assert_response :success
    assert_select "#whatsapp-cta", count: 0
    assert_select "form#new_guest_session"
  end

  # There is nothing in this link to steal, and that is deliberate: the room
  # binding happens in conversation, not in a URL anyone can screenshot.
  test "the link carries nothing identifying — no token, no session, no ids" do
    get hotel_landing_path(hotels(:stari_grad).slug)

    href = css_select("#whatsapp-cta").first.attr("href")

    assert_no_match(/token|session|guest_id|hotel_id/i, href)
    # Only the number and the greeting, and nothing else — asserted as the
    # whole shape rather than as an absence, so a future parameter has to be
    # added here deliberately instead of slipping in unnoticed.
    assert_match %r{\Ahttps://wa\.me/\d+\?text=[^&]+\z}, href
  end

  # The greeting is prefilled because Meta's 24-hour window only opens once
  # the *guest* writes — an empty composer is a guest wondering what to say.
  test "the link prefills a greeting in the guest's own language" do
    get hotel_landing_path(hotels(:stari_grad).slug), headers: { "Accept-Language" => "de" }

    href = css_select("#whatsapp-cta").first.attr("href")
    # The literal German from config/locales/guest.de.yml, pasted rather than
    # looked up through I18n.t — deriving it from the file the view reads
    # would pass however empty that key became (engineering rule 2).
    assert_includes CGI.unescape(href), "Hallo! Ich wohne im #{hotels(:stari_grad).name}."
  end
end
