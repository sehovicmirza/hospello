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
end
