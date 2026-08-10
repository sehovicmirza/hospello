module Ai
  # HTTP 429. The account is over its request or token rate.
  #
  # `retry_after` carries the API's own `retry-after` header in seconds when it
  # sent one, so a caller can back off by the amount the server actually asked
  # for rather than guessing. It is nil when the header was absent — treat that
  # as "no advice given", not as "retry immediately".
  class RateLimitedError < Error
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end
end
