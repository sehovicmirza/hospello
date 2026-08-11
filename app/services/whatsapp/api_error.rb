module Whatsapp
  # Any other failure: a 4xx that is not 401, a 5xx, a connection that never
  # opened, or a missing WHATSAPP_ACCESS_TOKEN.
  #
  # `status` is the HTTP status when there was one, and nil otherwise (a
  # connection failure, or the local guard for an unconfigured access
  # token) — the same shape Ai::ApiError keeps around Anthropic failures.
  class ApiError < Error
    attr_reader :status

    def initialize(message = nil, status: nil)
      super(message)
      @status = status
    end
  end
end
