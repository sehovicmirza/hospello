require "test_helper"

# Rack::Attack is disabled by default in the test environment
# (config/environments/test.rb) so shared throttle counters can't make
# unrelated tests flaky. These tests turn it on explicitly and point it at a
# real, request-persistent cache store — Rails.cache is :null_store in test
# (config/environments/test.rb), which never actually remembers a count
# between requests, so throttling would silently never trigger against it.
class RackAttackTest < ActionDispatch::IntegrationTest
  setup do
    @original_enabled = Rack::Attack.enabled
    @original_store = Rack::Attack.cache.store
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.reset!

    # Rack::Attack counts requests into fixed one-minute wall-clock buckets.
    # A real minute boundary rolling over mid-loop (rare, but seen once in a
    # 60-plus-request test) would silently reset the count partway through
    # and the throttle would never trip — freezing time removes that flake
    # instead of hoping the loop finishes inside one bucket.
    travel_to Time.current
  end

  teardown do
    travel_back
    Rack::Attack.enabled = @original_enabled
    Rack::Attack.cache.store = @original_store
  end

  # /h/<slug> doesn't exist as a route until Slice 2, but Rack::Attack
  # throttles at the Rack layer, before routing resolves — so the requests
  # under the limit 404 (there is no controller yet), and the throttle still
  # fires on the 21st regardless.
  test "throttles POSTs to /h/... guest entry paths after 20 requests per minute" do
    20.times do
      post "/h/some-hotel-slug"
      assert_not_equal 429, response.status
    end

    post "/h/some-hotel-slug"
    assert_equal 429, response.status
  end

  test "throttles POSTs to /guest/... after 60 requests per minute" do
    60.times do
      post "/guest/some-hotel-slug/messages"
      assert_not_equal 429, response.status
    end

    post "/guest/some-hotel-slug/messages"
    assert_equal 429, response.status
  end

  test "throttles POSTs to the session (login) path after 10 requests per minute" do
    10.times do
      post session_path, params: { email_address: "nobody@example.com", password: "wrong" }
      assert_not_equal 429, response.status
    end

    post session_path, params: { email_address: "nobody@example.com", password: "wrong" }
    assert_equal 429, response.status
  end

  test "never throttles /up" do
    25.times { get "/up" }

    get "/up"
    assert_not_equal 429, response.status
  end

  test "does not throttle GETs to guest entry paths under the POST-only guest_entry rule" do
    25.times { get "/h/some-hotel-slug" }

    get "/h/some-hotel-slug"
    assert_not_equal 429, response.status
  end

  # Slice 2 adds real routes behind the "/h/..." and "/guest/..." literals
  # config/initializers/rack_attack.rb's throttles match on — HotelQrCode#path
  # (what's physically printed on a hotel's QR card) and the guest chat
  # route. The two tests above already pin the throttle to a same-shaped
  # hardcoded literal; these two instead derive the path from the actual
  # route helpers, so a rename that keeps "/h/..."-shaped URLs working in
  # general but moves *these specific* routes elsewhere would still be
  # caught here even though it wouldn't be caught above.
  test "throttles POSTs to the real hotel landing route, not just a same-shaped literal" do
    path = Rails.application.routes.url_helpers.hotel_landing_path(hotels(:stari_grad).slug)

    20.times do
      post path
      assert_not_equal 429, response.status
    end

    post path
    assert_equal 429, response.status
  end

  test "throttles POSTs under the real guest chat route's namespace, not just a same-shaped literal" do
    path = Rails.application.routes.url_helpers.guest_chat_path

    60.times do
      post path
      assert_not_equal 429, response.status
    end

    post path
    assert_equal 429, response.status
  end

  test "is a no-op when disabled, however many requests arrive" do
    Rack::Attack.enabled = false

    25.times { post "/h/some-hotel-slug" }

    post "/h/some-hotel-slug"
    assert_not_equal 429, response.status
  end

  # Render sits an SSL-terminating proxy in front of Puma (force_ssl = true,
  # config/environments/production.rb), so REMOTE_ADDR as the app sees it is
  # that proxy, not the guest — every throttle has to resolve the real
  # client from X-Forwarded-For instead. config/environments/test.rb adds
  # 203.0.113.0/24 (RFC 5737's documentation-only range) to
  # trusted_proxies specifically so this proxy hop is simulatable: REMOTE_ADDR
  # inside that range is what "a request arriving through the trusted proxy"
  # looks like here.
  #
  # A plain req.ip can't see config.action_dispatch.trusted_proxies at all —
  # it has its own hardcoded, separate idea of which REMOTE_ADDRs to trust,
  # which does not include this test range. Under that resolution, this
  # proxy IP would be treated as untrusted, X-Forwarded-For would be ignored
  # entirely, and both clients below would collapse into one throttle bucket
  # keyed on the proxy's own address — a single abusive guest 429ing the
  # whole hotel, including staff sign-ins through the same proxy.
  test "requests behind the trusted proxy get independent throttle buckets per real client" do
    proxy_ip = "203.0.113.1"
    client_a = "198.51.100.10"
    client_b = "198.51.100.20"

    10.times do
      post session_path,
        params: { email_address: "nobody@example.com", password: "wrong" },
        env: { "REMOTE_ADDR" => proxy_ip },
        headers: { "X-Forwarded-For" => client_a }
      assert_not_equal 429, response.status
    end

    post session_path,
      params: { email_address: "nobody@example.com", password: "wrong" },
      env: { "REMOTE_ADDR" => proxy_ip },
      headers: { "X-Forwarded-For" => client_a }
    assert_equal 429, response.status, "client_a should be throttled after 10 requests"

    post session_path,
      params: { email_address: "nobody@example.com", password: "wrong" },
      env: { "REMOTE_ADDR" => proxy_ip },
      headers: { "X-Forwarded-For" => client_b }
    assert_not_equal 429, response.status,
      "client_b, behind the same proxy, must not share client_a's bucket"
  end

  # The other half of the same trust boundary: a connection that does NOT
  # arrive through the trusted proxy (REMOTE_ADDR outside every trusted
  # range) must not get to pick its own bucket just by sending a different
  # X-Forwarded-For value on every request — otherwise the throttle is
  # trivially defeated by rotating a header, no botnet required.
  test "a forged X-Forwarded-For from a direct, untrusted connection cannot escape its own bucket" do
    attacker_ip = "198.51.100.99"

    10.times do |i|
      post session_path,
        params: { email_address: "nobody@example.com", password: "wrong" },
        env: { "REMOTE_ADDR" => attacker_ip },
        headers: { "X-Forwarded-For" => "1.2.3.#{i}" }
      assert_not_equal 429, response.status
    end

    post session_path,
      params: { email_address: "nobody@example.com", password: "wrong" },
      env: { "REMOTE_ADDR" => attacker_ip },
      headers: { "X-Forwarded-For" => "9.9.9.9" }
    assert_equal 429, response.status,
      "a forged X-Forwarded-For must not let an untrusted direct connection dodge its own throttle bucket"
  end

  # Slice 6's webhook safelist (config/initializers/rack_attack.rb). Two
  # layers: the class method's own body/rewind behavior in isolation below,
  # then the full safelist wired into a real, currently-active throttle —
  # today no throttle rule actually matches /webhooks/whatsapp (none of the
  # four above look at that path), so a test that only proved "a verified
  # request to /webhooks/whatsapp is never 429'd" would pass whether or not
  # the safelist code exists at all. Registering a throttle that DOES match
  # it, just for the duration of one test, is what makes this a real,
  # breakable proof of the exemption rather than an accident of no rule
  # colliding with it yet.
  module WhatsappWebhookSafelistHelpers
    APP_SECRET = "test-whatsapp-rack-attack-secret"

    def with_whatsapp_app_secret(secret = APP_SECRET)
      original = Rails.configuration.x.whatsapp.app_secret
      Rails.configuration.x.whatsapp.app_secret = secret
      yield
    ensure
      Rails.configuration.x.whatsapp.app_secret = original
    end

    def whatsapp_signature(body, secret: APP_SECRET)
      "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    end

    # A real Rack::Attack::Request (the app's own subclass, not a bare
    # Rack::Request) over a genuinely rewindable body — Rack::MockRequest's
    # :input option wraps a String in exactly the kind of IO a real Rack
    # server hands the app.
    def whatsapp_rack_request(body, signature:)
      env = Rack::MockRequest.env_for("/webhooks/whatsapp", method: "POST", input: body)
      env["HTTP_X_HUB_SIGNATURE_256"] = signature if signature
      Rack::Attack::Request.new(env)
    end
  end
  include WhatsappWebhookSafelistHelpers

  test "verified_whatsapp_signature? accepts a correctly signed body and leaves it rewound for the next reader" do
    # +'...' (not a bare literal): this string is handed to
    # Rack::MockRequest/Rack::Test, which wraps it in a StringIO and calls a
    # mutating method on it — harmless on an ordinary String, but Ruby 3.4's
    # "chilled string" transition warns the first time any literal receives
    # one. Unary + makes it explicitly unfrozen up front.
    body = +'{"object":"whatsapp_business_account","entry":[]}'

    with_whatsapp_app_secret do
      req = whatsapp_rack_request(body, signature: whatsapp_signature(body))

      assert Rack::Attack.verified_whatsapp_signature?(req)
      assert_equal body, req.body.read,
        "the body must still be fully, byte-for-byte readable downstream — a missing rewind would silently empty every real webhook's body"
    end
  end

  test "verified_whatsapp_signature? refuses a forged signature and still leaves the body rewound" do
    body = +'{"object":"whatsapp_business_account","entry":[]}' # +'...': see the first test above

    with_whatsapp_app_secret do
      req = whatsapp_rack_request(body, signature: "sha256=" + ("0" * 64))

      assert_not Rack::Attack.verified_whatsapp_signature?(req)
      assert_equal body, req.body.read, "even a REFUSED request must leave the body rewound for the controller to read"
    end
  end

  test "verified_whatsapp_signature? refuses a request with no signature header at all" do
    body = +'{"object":"whatsapp_business_account","entry":[]}' # +'...': see the first test above

    with_whatsapp_app_secret do
      req = whatsapp_rack_request(body, signature: nil)

      assert_not Rack::Attack.verified_whatsapp_signature?(req)
    end
  end

  test "a verified WhatsApp webhook delivery is exempt from a throttle that would otherwise match it" do
    Rack::Attack.throttle("test_whatsapp_throttle_for_this_test", limit: 2, period: 1.minute) do |req|
      req.path == "/webhooks/whatsapp"
    end

    with_whatsapp_app_secret do
      body = +'{"object":"whatsapp_business_account","entry":[]}' # +'...': see the first test above
      good_headers = { "CONTENT_TYPE" => "application/json", "X-Hub-Signature-256" => whatsapp_signature(body) }
      bad_headers  = { "CONTENT_TYPE" => "application/json", "X-Hub-Signature-256" => "sha256=" + ("0" * 64) }

      # Exhaust the throttle's limit with unverified deliveries — each one
      # is genuinely refused by the controller itself (401), which is a
      # different thing from being throttled (429): this loop proves the
      # throttle is real and active, not merely declared.
      2.times do
        post "/webhooks/whatsapp", params: body, headers: bad_headers
        assert_response :unauthorized
      end
      post "/webhooks/whatsapp", params: body, headers: bad_headers
      assert_equal 429, response.status, "an unverified delivery must still be throttled normally once the limit is exceeded"

      # A verified delivery, arriving after that same limit was already
      # exhausted by the unverified ones above, must sail through anyway —
      # this is the property the safelist exists to guarantee.
      post "/webhooks/whatsapp", params: body, headers: good_headers
      assert_not_equal 429, response.status
      assert_response :success
    end
  ensure
    Rack::Attack.throttles.delete("test_whatsapp_throttle_for_this_test")
  end
end
