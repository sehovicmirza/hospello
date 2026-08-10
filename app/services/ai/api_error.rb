module Ai
  # Any other failure from the API or the transport: 4xx, 5xx, a connection
  # that never opened, or a missing API key.
  #
  # `status` is the HTTP status when there was one and nil otherwise (a
  # connection failure, or the local guard for an unset `ANTHROPIC_API_KEY`).
  # `server_error?` is the distinction the circuit breaker needs: a 5xx is the
  # API having a bad minute and is worth backing off from, while a 400 is our
  # own request being wrong and will fail identically forever. Opening the
  # breaker on the second one would take the concierge down for every hotel
  # over a single malformed prompt.
  class ApiError < Error
    attr_reader :status

    def initialize(message = nil, status: nil)
      super(message)
      @status = status
    end

    def server_error? = status.to_i >= 500
  end
end
