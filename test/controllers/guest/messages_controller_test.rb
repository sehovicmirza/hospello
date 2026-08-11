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

  # The resync endpoint is the sharper half of the internal-note leak
  # boundary: it hands back whatever arrived since the guest last looked,
  # with no page reload for anyone to notice, so a note written seconds ago
  # would go straight to the guest's phone. The guest-visible reply posted
  # *after* the note is what makes this test able to fail — it proves the
  # response really did carry everything past `after`, and that the note
  # was filtered rather than the whole tail being cut off at it.
  test "GET index never returns an internal note, even when it falls inside the ?after= window" do
    sign_in_guest("stari-grad-fixture-guest-token")
    hotel = hotels(:stari_grad)
    conversation = with_tenant(hotel) { Conversation.live_for(guest_sessions(:stari_guest)) }
    marker = with_tenant(hotel) { conversation.post_guest_message!(body: "the-marker-body", client_message_id: SecureRandom.uuid) }
    with_tenant(hotel) { conversation.post_internal_note!(user: users(:stari_staff), body: "internal-only-body") }
    with_tenant(hotel) { conversation.post_staff_message!(user: users(:stari_staff), body: "guest-visible-reply-body") }

    get guest_messages_path, params: { after: marker.id }, headers: { "Accept" => TURBO_STREAM_ACCEPT }

    assert_response :success
    assert_no_match "internal-only-body", response.body
    assert_match "guest-visible-reply-body", response.body
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

    # freeze_time, because the limit is 100 requests *within one minute* and
    # this test makes 101 of them. On an unloaded machine that takes about a
    # second and the window never matters; on a busy one — CI, or a laptop
    # running the suite beside something else — those requests can span more
    # than sixty seconds, the earliest ones fall out of the window, and the
    # last request is then genuinely not over the limit. The test failed
    # exactly that way in a full-suite run that took 445s while other work
    # was competing for the machine, and passed in 2.5s alone minutes later,
    # with no code change in between. That is a test measuring the machine
    # rather than the rate limiter. Freezing the clock makes the burst
    # instantaneous by definition, so what is asserted is the limit itself.
    freeze_time do
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

  # The complement, and the reason the window is worth having at all: a guest
  # who hits the limit is not banned, only slowed. Without this, shortening
  # `within:` to a second — or removing the window entirely and never letting
  # anyone through again — would leave the suite green.
  test "a rate-limited session is allowed through again once the window passes" do
    hotel = hotels(:stari_grad)
    raw_token = SecureRandom.urlsafe_base64(32)
    with_tenant(hotel) do
      hotel.guest_sessions.create!(
        guest_name: "Recovering Guest", locale: "en", privacy_accepted_at: Time.current,
        expires_at: 7.days.from_now, token_digest: GuestSession.digest(raw_token)
      )
    end
    sign_in_guest(raw_token)

    freeze_time do
      (Guest::MessagesController::RATE_LIMIT_MAX + 1).times do
        post guest_messages_path,
          params: { message: { body: "hi", client_message_id: SecureRandom.uuid } },
          headers: { "Accept" => TURBO_STREAM_ACCEPT }
      end
      assert_response :too_many_requests
    end

    travel 2.minutes do
      post guest_messages_path,
        params: { message: { body: "let me back in", client_message_id: SecureRandom.uuid } },
        headers: { "Accept" => TURBO_STREAM_ACCEPT }

      assert_response :success
    end
  end
end
