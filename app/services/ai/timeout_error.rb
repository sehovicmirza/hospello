module Ai
  # The request did not come back in time.
  #
  # Retryable in principle, and counted by the circuit breaker. Worth knowing:
  # the gem applies its own retries *inside* one `Ai::Client#chat` call, so by
  # the time this reaches a caller the request has already been attempted more
  # than once and the wall-clock cost is a multiple of the configured timeout.
  # See `Ai::Client::MAX_RETRIES`.
  class TimeoutError < Error; end
end
