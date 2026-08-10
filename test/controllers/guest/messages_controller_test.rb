require "test_helper"

# Guest::BaseController (see that controller) does the tenant/session
# resolution every action here inherits — these tests exercise what this
# controller adds on top of it. Cross-hotel isolation for posting/resyncing
# lives in test/tenancy/cross_tenant_access_test.rb, per that file's own
# scope (every other tenant-boundary test in this app lives there too).
class Guest::MessagesControllerTest < ActionDispatch::IntegrationTest
  TURBO_STREAM_ACCEPT = "text/vnd.turbo-stream.html"

  test "POST create with a valid cookie creates one message and returns a turbo stream" do
    sign_in_guest("stari-grad-fixture-guest-token")
    hotel = hotels(:stari_grad)

    assert_difference -> { with_tenant(hotel) { Message.count } }, 1 do
      post guest_messages_path,
        params: { message: { body: "Can I get extra towels?", client_message_id: SecureRandom.uuid } },
        headers: { "Accept" => TURBO_STREAM_ACCEPT }
    end

    assert_response :success
    assert_equal Mime[:turbo_stream].to_s, response.media_type
    assert_match "Can I get extra towels?", response.body
  end

  test "posting the same client_message_id twice creates exactly one message" do
    sign_in_guest("stari-grad-fixture-guest-token")
    hotel = hotels(:stari_grad)
    client_message_id = SecureRandom.uuid
    params = { message: { body: "Room service please", client_message_id: client_message_id } }

    post guest_messages_path, params: params, headers: { "Accept" => TURBO_STREAM_ACCEPT }
    assert_response :success

    assert_no_difference -> { with_tenant(hotel) { Message.count } } do
      post guest_messages_path, params: params, headers: { "Accept" => TURBO_STREAM_ACCEPT }
    end
    assert_response :success
  end

  # guest_sessions(:stari_guest) is locale: bs (see test/fixtures/guest_sessions.yml)
  # — Guest::BaseController activates that locale for the whole request
  # (GuestLocalization), so the friendly error actually renders in
  # Bosnian, not English. Asserting the literal Bosnian string (pasted
  # from config/locales/guest.bs.yml, not looked up via t() here) is what
  # proves the *right* language rendered — I18n.t("...") in the test would
  # pass even if the key held nothing at all, or the wrong locale.
  test "a message longer than 1000 characters is rejected with a friendly error, in the guest's own language" do
    sign_in_guest("stari-grad-fixture-guest-token")
    hotel = hotels(:stari_grad)

    assert_no_difference -> { with_tenant(hotel) { Message.count } } do
      post guest_messages_path,
        params: { message: { body: "a" * 1001, client_message_id: SecureRandom.uuid } },
        headers: { "Accept" => TURBO_STREAM_ACCEPT }
    end

    assert_response :unprocessable_content
    assert_match "Vaša poruka je preduga. Molimo skratite je i pokušajte ponovo.", response.body
  end

  test "an empty message is rejected and creates nothing" do
    sign_in_guest("stari-grad-fixture-guest-token")
    hotel = hotels(:stari_grad)

    assert_no_difference -> { with_tenant(hotel) { Message.count } } do
      post guest_messages_path,
        params: { message: { body: "", client_message_id: SecureRandom.uuid } },
        headers: { "Accept" => TURBO_STREAM_ACCEPT }
    end

    assert_response :unprocessable_content
  end

  test "a whitespace-only message is rejected and creates nothing" do
    sign_in_guest("stari-grad-fixture-guest-token")
    hotel = hotels(:stari_grad)

    assert_no_difference -> { with_tenant(hotel) { Message.count } } do
      post guest_messages_path,
        params: { message: { body: "   \n\t  ", client_message_id: SecureRandom.uuid } },
        headers: { "Accept" => TURBO_STREAM_ACCEPT }
    end

    assert_response :unprocessable_content
  end

  test "POST create without a cookie renders the re-entry page, not a 500" do
    post guest_messages_path,
      params: { message: { body: "hello", client_message_id: SecureRandom.uuid } },
      headers: { "Accept" => TURBO_STREAM_ACCEPT }

    assert_response :unauthorized
    assert_select "#guest-re-entry"
  end

  test "GET index with ?after= returns only messages newer than that id" do
    sign_in_guest("stari-grad-fixture-guest-token")
    hotel = hotels(:stari_grad)
    conversation = with_tenant(hotel) { Conversation.live_for(guest_sessions(:stari_guest)) }
    first = with_tenant(hotel) { conversation.post_guest_message!(body: "the-first-unique-body", client_message_id: SecureRandom.uuid) }
    second = with_tenant(hotel) { conversation.post_guest_message!(body: "the-second-unique-body", client_message_id: SecureRandom.uuid) }

    get guest_messages_path, params: { after: first.id }, headers: { "Accept" => TURBO_STREAM_ACCEPT }

    assert_response :success
    assert_no_match "the-first-unique-body", response.body
    assert_match "the-second-unique-body", response.body
  end

  test "GET index with no ?after= returns every message in the conversation" do
    sign_in_guest("stari-grad-fixture-guest-token")
    hotel = hotels(:stari_grad)
    conversation = with_tenant(hotel) { Conversation.live_for(guest_sessions(:stari_guest)) }
    with_tenant(hotel) { conversation.post_guest_message!(body: "only-message-here", client_message_id: SecureRandom.uuid) }

    get guest_messages_path, headers: { "Accept" => TURBO_STREAM_ACCEPT }

    assert_response :success
    assert_match "only-message-here", response.body
  end

  test "GET index without a cookie renders the re-entry page, not a 500" do
    get guest_messages_path, headers: { "Accept" => TURBO_STREAM_ACCEPT }

    assert_response :unauthorized
    assert_select "#guest-re-entry"
  end

  # Rails' rate_limit, layered on top of rack-attack's IP throttle
  # (config/initializers/rack_attack.rb, disabled in test — see that
  # file), keyed by guest_session id specifically so one abusive session
  # is throttled without affecting any other guest sharing the same IP
  # (hotel wifi/NAT). Uses a fresh guest_session rather than a shared
  # fixture: the rate limiter's counter is real, in-process state that
  # persists for the life of the test-worker process, so reusing
  # guest_sessions(:stari_guest) here would make this test's pass/fail
  # depend on how many *other* tests in the same worker also POST as that
  # fixture — a shared-state trap the house rules warn about.
  test "an abusive session is rate-limited on top of rack-attack's IP throttle" do
    hotel = hotels(:stari_grad)
    raw_token = SecureRandom.urlsafe_base64(32)
    with_tenant(hotel) do
      hotel.guest_sessions.create!(
        guest_name: "Rate Limit Guest", locale: "en", privacy_accepted_at: Time.current,
        expires_at: 7.days.from_now, token_digest: GuestSession.digest(raw_token)
      )
    end
    sign_in_guest(raw_token)

    Guest::MessagesController::RATE_LIMIT_MAX.times do
      post guest_messages_path,
        params: { message: { body: "hi", client_message_id: SecureRandom.uuid } },
        headers: { "Accept" => TURBO_STREAM_ACCEPT }
    end
    assert_response :success

    post guest_messages_path,
      params: { message: { body: "one too many", client_message_id: SecureRandom.uuid } },
      headers: { "Accept" => TURBO_STREAM_ACCEPT }

    assert_response :too_many_requests
  end
end
