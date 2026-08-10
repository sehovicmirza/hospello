module Ai
  # Stops calling a model that is not answering.
  #
  # Without this, an API outage costs a full timeout per guest message, for
  # every guest, for as long as the outage lasts — each one holding a job slot
  # and each one making the guest wait half a minute before the fallback
  # message they were always going to get. The breaker turns the second and
  # subsequent failures into an instant fallback.
  #
  # State lives in the cache, per hotel, because that is the granularity that
  # matters: a hotel whose knowledge base provokes a persistent 400 should not
  # take the concierge down for every other hotel.
  #
  # **Only timeouts and 5xx count.** A 400 fails identically forever, so
  # counting it would open the breaker permanently on one bad prompt. See
  # `Ai::ApiError#server_error?`.
  #
  # A note for tests: `config.cache_store` is `:null_store` in this
  # environment, so a breaker on the default store silently never opens. Any
  # test about breaker behaviour has to pass a real store — see
  # test/services/ai/circuit_breaker_test.rb.
  class CircuitBreaker
    FAILURE_THRESHOLD = 4

    # Consecutive failures have to arrive inside this window to count as a
    # streak. Four failures spread over an afternoon are four unlucky guests,
    # not an outage, and opening the breaker for them would take the concierge
    # away from everyone else for no reason.
    FAILURE_WINDOW = 3.minutes

    # How long the breaker stays open before it lets one call through to see
    # whether the API has recovered. Short enough that a brief outage does not
    # cost a hotel its concierge for the evening.
    PROBE_AFTER = 2.minutes

    def initialize(hotel, store: Rails.cache)
      @hotel = hotel
      @store = store
    end

    # False when the breaker is open and the probe interval has not elapsed.
    # The half-open probe is implicit: once `PROBE_AFTER` has passed the open
    # marker has expired, so exactly one call goes through and its result
    # decides what happens next — a success clears the streak, a failure
    # re-opens for another interval.
    def closed? = store.read(open_key).blank?

    def record_success
      store.delete(failures_key)
      store.delete(open_key)
    end

    # @param error [Ai::Error] the failure to count, or nil for a
    #   non-exception failure that should still count (a truncation, say).
    def record_failure(error = nil)
      return if error.is_a?(ApiError) && !error.server_error?

      failures = store.read(failures_key).to_i + 1
      # The window is enforced by the entry's own expiry: a streak that stops
      # for FAILURE_WINDOW expires and the next failure starts from one.
      store.write(failures_key, failures, expires_in: FAILURE_WINDOW)

      open! if failures >= FAILURE_THRESHOLD
    end

    def open!
      store.write(open_key, true, expires_in: PROBE_AFTER)
      store.delete(failures_key)
    end

    def open? = !closed?

    private

    attr_reader :hotel, :store

    def failures_key = "ai:breaker:#{hotel.id}:failures"
    def open_key = "ai:breaker:#{hotel.id}:open"
  end
end
