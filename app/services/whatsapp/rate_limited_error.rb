module Whatsapp
  # HTTP 429 — the WABA or the app itself is over Meta's rate limit.
  #
  # Worth retrying later, unlike Whatsapp::AuthenticationError — which is
  # exactly why it is its own type rather than a status code buried inside
  # Whatsapp::ApiError. `retry_after` carries Meta's own `retry-after`
  # header in seconds when it sent one; nil means no advice was given, never
  # "retry immediately" — the same contract Ai::RateLimitedError keeps
  # around Anthropic's own header.
  class RateLimitedError < Error
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end
end
