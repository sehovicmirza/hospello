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
end
