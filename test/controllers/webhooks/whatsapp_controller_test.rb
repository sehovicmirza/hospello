require "test_helper"

module Webhooks
  # POST /webhooks/whatsapp is the only unauthenticated, publicly reachable
  # endpoint in this app that accepts a body — the front door for any real
  # guest message AND for anyone on the internet with a crafted request.
  # Every "must be refused" test below signs (or deliberately fails to sign)
  # a REAL request the way an actual attacker would have to, and asserts
  # both the HTTP response AND that nothing was written/enqueued — a test
  # that only checked the status code could pass while quietly leaving a
  # forged row in the table.
  class WhatsappControllerTest < ActionDispatch::IntegrationTest
    APP_SECRET = "test-whatsapp-app-secret"
    VERIFY_TOKEN = "test-webhook-verify-token"

    setup do
      @original_app_secret = Rails.configuration.x.whatsapp.app_secret
      @original_verify_token = Rails.configuration.x.whatsapp.webhook_verify_token
      Rails.configuration.x.whatsapp.app_secret = APP_SECRET
      Rails.configuration.x.whatsapp.webhook_verify_token = VERIFY_TOKEN
    end

    teardown do
      Rails.configuration.x.whatsapp.app_secret = @original_app_secret
      Rails.configuration.x.whatsapp.webhook_verify_token = @original_verify_token
    end

    # Meta's own documented shape
    # (https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/payload-examples),
    # with several sibling keys under `value` — not a trivial one-key body.
    # This matters for what these tests actually prove: params always has
    # "controller"/"action" merged in by Rails' own routing on top of
    # whatever the body contained, so a bug that accidentally signed
    # params.to_json instead of request.raw_post would fail EVERY test
    # below that expects success, not just a contrived reordering case.
    def inbound_message_payload(message_id: "wamid.HBgLTEST1==")
      {
        "object" => "whatsapp_business_account",
        "entry" => [
          {
            "id" => "waba-id-123",
            "changes" => [
              {
                "field" => "messages",
                "value" => {
                  "messaging_product" => "whatsapp",
                  "metadata" => { "display_phone_number" => "38761100100", "phone_number_id" => "fixture-phone-number-id-stari" },
                  "contacts" => [ { "profile" => { "name" => "Guest Name" }, "wa_id" => "38761999999" } ],
                  "messages" => [
                    { "from" => "38761999999", "id" => message_id, "timestamp" => "1691600000", "type" => "text", "text" => { "body" => "Hello" } }
                  ]
                }
              }
            ]
          }
        ]
      }
    end

    def sign(body, secret: APP_SECRET)
      "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    end

    def post_webhook(body, signature: sign(body))
      headers = { "CONTENT_TYPE" => "application/json" }
      headers["X-Hub-Signature-256"] = signature if signature

      post webhooks_whatsapp_path, params: body, headers: headers
    end

    # --- GET: Meta's subscription handshake ------------------------------

    test "a GET handshake with the right verify token echoes hub.challenge" do
      get webhooks_whatsapp_path, params: { "hub.mode" => "subscribe", "hub.verify_token" => VERIFY_TOKEN, "hub.challenge" => "challenge-abc-123" }

      assert_response :success
      assert_equal "challenge-abc-123", response.body
    end

    test "a GET handshake with a wrong verify token is refused" do
      get webhooks_whatsapp_path, params: { "hub.mode" => "subscribe", "hub.verify_token" => "guessed-wrong", "hub.challenge" => "challenge-abc-123" }

      assert_response :forbidden
      assert_not_equal "challenge-abc-123", response.body
      assert_empty response.body
    end

    test "a GET handshake with no verify token at all is refused" do
      get webhooks_whatsapp_path, params: { "hub.mode" => "subscribe", "hub.challenge" => "challenge-abc-123" }

      assert_response :forbidden
      assert_empty response.body
    end

    test "a GET handshake with the right token but the wrong hub.mode is refused" do
      get webhooks_whatsapp_path, params: { "hub.mode" => "unsubscribe", "hub.verify_token" => VERIFY_TOKEN, "hub.challenge" => "challenge-abc-123" }

      assert_response :forbidden
      assert_empty response.body
    end

    # A misconfigured deployment (WHATSAPP_WEBHOOK_VERIFY_TOKEN never set)
    # must refuse the handshake outright, never accept it just because there
    # was nothing configured to check against.
    test "a GET handshake refuses everything when no verify token is configured" do
      Rails.configuration.x.whatsapp.webhook_verify_token = nil

      get webhooks_whatsapp_path, params: { "hub.mode" => "subscribe", "hub.verify_token" => "", "hub.challenge" => "challenge-abc-123" }

      assert_response :forbidden
    end

    # --- POST: a real delivery, and the signature boundary ----------------

    test "a POST with a valid X-Hub-Signature-256 is accepted" do
      body = inbound_message_payload.to_json

      assert_difference "WebhookEvent.count", 1 do
        post_webhook(body)
      end

      assert_response :success
      event = WebhookEvent.last
      assert_equal "wamid.HBgLTEST1==", event.external_id
      assert event.meta_cloud?
      assert event.received?
      assert_nil event.hotel_id
    end

    test "a POST with no signature header is refused" do
      body = inbound_message_payload.to_json

      assert_no_difference "WebhookEvent.count" do
        post_webhook(body, signature: nil)
      end

      assert_response :unauthorized
      assert_no_enqueued_jobs
    end

    test "a POST with a blank signature header is refused" do
      body = inbound_message_payload.to_json

      assert_no_difference "WebhookEvent.count" do
        post_webhook(body, signature: "")
      end

      assert_response :unauthorized
    end

    # The signature is valid for SOME body, just not the one that arrived —
    # an attacker who has seen one legitimately-signed payload cannot reuse
    # its signature to get a different, chosen body accepted.
    test "a POST whose signature was computed over a different body is refused" do
      real_body = inbound_message_payload.to_json
      signature_for_other_payload = sign(inbound_message_payload(message_id: "wamid.SOMETHING-ELSE").to_json)

      assert_no_difference "WebhookEvent.count" do
        post_webhook(real_body, signature: signature_for_other_payload)
      end

      assert_response :unauthorized
    end

    # The real attack: a genuinely valid (body, signature) pair, tampered
    # with in flight after signing — the signature travels with the
    # ORIGINAL body's bytes, not with whatever now actually arrives.
    test "a POST whose body was modified after signing is refused" do
      original_body = inbound_message_payload.to_json
      original_signature = sign(original_body)
      tampered_body = original_body.sub("wamid.HBgLTEST1==", "wamid.ATTACKER-CHOSEN")

      assert_no_difference "WebhookEvent.count" do
        post_webhook(tampered_body, signature: original_signature)
      end

      assert_response :unauthorized
    end

    test "a rejected signature never enqueues a processing job" do
      body = inbound_message_payload.to_json

      assert_no_enqueued_jobs do
        post_webhook(body, signature: sign("a-completely-different-body"))
      end
    end

    # --- Idempotency: the guarantee the whole slice hinges on -------------

    test "two deliveries of the same provider message id create exactly ONE webhook_event" do
      body = inbound_message_payload.to_json

      post_webhook(body)
      assert_response :success

      assert_no_difference "WebhookEvent.count" do
        post_webhook(body)
      end
      assert_response :success, "a replay must still look like success to Meta, not an error that triggers more retries"
    end

    # A design decision beyond the brief's literal wording, worth its own
    # explicit test: a replay still enqueues a processing job, because a
    # webhook_events row that was inserted but never got its job enqueued
    # (e.g. a crash between the two) can ONLY be recovered by a later Meta
    # retry — collapsing "deduplicated" and "never processed" into the same
    # no-op would silently lose a guest's message.
    test "a replay still enqueues a job for the existing row, not only the first delivery" do
      body = inbound_message_payload.to_json

      post_webhook(body)
      event_id = WebhookEvent.last.id

      assert_enqueued_with(job: Whatsapp::ProcessInboundJob, args: [ event_id ]) do
        post_webhook(body)
      end
    end

    test "different provider message ids create separate webhook_events" do
      post_webhook(inbound_message_payload(message_id: "wamid.FIRST").to_json)

      assert_difference "WebhookEvent.count", 1 do
        post_webhook(inbound_message_payload(message_id: "wamid.SECOND").to_json)
      end
    end

    # --- Speed and asynchrony ----------------------------------------------

    test "the endpoint answers in under a second and does the work in a job" do
      body = inbound_message_payload.to_json

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_enqueued_with(job: Whatsapp::ProcessInboundJob) do
        post_webhook(body)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_response :success
      assert_operator elapsed, :<, 1.0, "the webhook handler took #{elapsed}s — Meta retries anything slow"
    end

    # --- Malformed bodies: never raise, never retry-storm ------------------

    test "a signature-verified but non-JSON body is answered 200, not 500, and creates no row" do
      # +"..." (not a bare literal): Rack::MockRequest wraps the posted body
      # in a StringIO and calls #set_encoding on it, which mutates the
      # string in place — harmless on an ordinary String, but Ruby 3.4's
      # "chilled string" transition warns on any literal that receives a
      # mutating call, however indirectly. Unary + makes this an explicitly
      # unfrozen, freshly-allocated string, same as everywhere else in this
      # file (String#to_json already returns one), so the warning has
      # nothing to fire on.
      body = +"this is not json"

      calls = capture_sentry_exceptions do
        assert_no_difference "WebhookEvent.count" do
          post_webhook(body)
        end
      end

      assert_response :success
      assert_equal 1, calls.size
      assert_kind_of JSON::ParserError, calls.first
    end

    # --- CSRF: there is no session for a token to protect -------------------

    # config/environments/test.rb turns forgery protection off app-wide
    # (config.action_controller.allow_forgery_protection = false) precisely
    # so ordinary controller tests don't need a token — which also means an
    # ordinary test here could not tell "CSRF is correctly skipped" apart
    # from "CSRF is simply off in test." Flipping protection back on for
    # this one request (mirroring test/integration/rack_attack_test.rb's own
    # pattern of re-enabling a normally test-disabled feature) makes this a
    # real, breakable proof: deleting this controller's own
    # skip_before_action would turn this into an ActionController::
    # InvalidAuthenticityToken instead of a 200.
    test "a POST with no CSRF token still succeeds, even with forgery protection genuinely turned on" do
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true

      body = inbound_message_payload.to_json
      post_webhook(body)

      assert_response :success
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    private
      def capture_sentry_exceptions
        original = Sentry.method(:capture_exception)
        calls = []
        Sentry.define_singleton_method(:capture_exception) { |exception, **_options| calls << exception }

        yield

        calls
      ensure
        Sentry.define_singleton_method(:capture_exception, original)
      end
  end
end
