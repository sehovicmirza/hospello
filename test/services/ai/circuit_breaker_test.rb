require "test_helper"

module Ai
  # The breaker exists so an API outage costs one timeout, not one timeout per
  # guest message for as long as the outage lasts.
  #
  # Every test here injects a real MemoryStore. `config.cache_store` is
  # `:null_store` in the test environment, so a breaker built on the default
  # would silently never open and every assertion below would pass for the
  # wrong reason — which is exactly the shape of test this project has been
  # burned by before.
  class CircuitBreakerTest < ActiveSupport::TestCase
    setup do
      @hotel = hotels(:stari_grad)
      @store = ActiveSupport::Cache::MemoryStore.new
      @breaker = Ai::CircuitBreaker.new(@hotel, store: @store)
    end

    test "starts closed" do
      assert @breaker.closed?
    end

    test "opens after a streak of failures" do
      (Ai::CircuitBreaker::FAILURE_THRESHOLD - 1).times { @breaker.record_failure(Ai::TimeoutError.new) }
      assert @breaker.closed?, "a hotel should not lose its concierge to three unlucky guests"

      @breaker.record_failure(Ai::TimeoutError.new)

      assert @breaker.open?
    end

    test "a success clears the streak" do
      (Ai::CircuitBreaker::FAILURE_THRESHOLD - 1).times { @breaker.record_failure(Ai::TimeoutError.new) }
      @breaker.record_success

      (Ai::CircuitBreaker::FAILURE_THRESHOLD - 1).times { @breaker.record_failure(Ai::TimeoutError.new) }

      assert @breaker.closed?
    end

    # Four failures spread over an afternoon are four unlucky guests, not an
    # outage. Opening for them would take the concierge away from everyone
    # else for no reason.
    test "failures spread beyond the window do not add up" do
      Ai::CircuitBreaker::FAILURE_THRESHOLD.times do
        @breaker.record_failure(Ai::TimeoutError.new)
        travel Ai::CircuitBreaker::FAILURE_WINDOW + 1.second
        @store.cleanup
      end

      assert @breaker.closed?
    ensure
      travel_back
    end

    # The distinction the whole class turns on: a 400 fails identically
    # forever, so counting it would open the breaker permanently on one bad
    # prompt — and take the concierge down for that hotel until someone
    # noticed.
    test "a client error never counts towards opening" do
      10.times { @breaker.record_failure(Ai::ApiError.new("bad request", status: 400)) }

      assert @breaker.closed?
    end

    test "a server error does count" do
      Ai::CircuitBreaker::FAILURE_THRESHOLD.times { @breaker.record_failure(Ai::ApiError.new("boom", status: 503)) }

      assert @breaker.open?
    end

    test "lets one call through once the probe interval has passed" do
      @breaker.open!
      assert @breaker.open?

      travel Ai::CircuitBreaker::PROBE_AFTER + 1.second
      @store.cleanup

      assert @breaker.closed?, "a brief outage must not cost a hotel its concierge for the evening"
    ensure
      travel_back
    end

    test "one hotel's outage does not close another hotel's concierge" do
      other = Ai::CircuitBreaker.new(hotels(:vrelo), store: @store)

      @breaker.open!

      assert @breaker.open?
      assert other.closed?
    end
  end
end
