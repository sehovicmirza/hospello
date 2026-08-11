require "net/http"

module Whatsapp
  # Meta's own Cloud API — the payload shape 360dialog also speaks (see the
  # plan's BSP discussion), so this is the one adapter Slice 6 ships even
  # though the port (Whatsapp::Provider) is built to hold more. Twilio is
  # the one documented BSP that does NOT speak this shape; that adapter
  # would be a genuinely new implementation of this same interface, not a
  # config change.
  #
  # The only file in the app that builds a WhatsApp HTTP request or parses
  # one of Meta's responses — everything above this layer talks to
  # Whatsapp::Provider and gets back a provider message id or a typed
  # Whatsapp::Error, the same seam discipline Ai::Client keeps around
  # Anthropic (see that class's own comment).
  class MetaCloudProvider < Provider
    # https://graph.facebook.com/<api_version>/<phone_number_id>/messages —
    # Meta Cloud API's one send endpoint, documented at
    # https://developers.facebook.com/docs/whatsapp/cloud-api/reference/messages.
    BASE_URL = "https://graph.facebook.com"

    # Per attempt. A guest is not watching a typing indicator the way they
    # are for the concierge (contrast Ai::Client::DEFAULT_TIMEOUT, shorter
    # for exactly that reason) but a wedged HTTP call must still not hold a
    # job's concurrency slot forever.
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 15

    def initialize(
      access_token: Rails.configuration.x.whatsapp.access_token,
      api_version: Rails.configuration.x.whatsapp.api_version
    )
      @access_token = access_token
      @api_version = api_version
    end

    def send_text(channel:, to:, body:, conversation:)
      raise WindowClosedError, window_closed_message(channel) if window_closed?(conversation)

      post(channel, {
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: to,
        type: "text",
        text: { body: body }
      })
    end

    # Never subject to the 24-hour window — see Whatsapp::Provider's class
    # comment for why a pre-approved template is exactly the exception
    # Meta's own rule carves out.
    def send_template(channel:, to:, name:, locale:, components: [])
      template = { name: name, language: { code: locale } }
      template[:components] = components if components.present?

      post(channel, {
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: to,
        type: "template",
        template: template
      })
    end

    private

    attr_reader :access_token, :api_version

    # More than 24 hours since the guest's last inbound message — Meta's own
    # customer-service-window rule (see WindowClosedError), computed exactly
    # as the brief specifies: Time.current > last_guest_message_at +
    # 24.hours, so a send at the exact boundary moment still succeeds. No
    # confirmed inbound message at all (nil) is treated as closed rather
    # than open — the safe default when the window cannot be proven open.
    def window_closed?(conversation)
      last_guest_message_at = conversation&.last_guest_message_at
      return true if last_guest_message_at.blank?

      Time.current > last_guest_message_at + 24.hours
    end

    def window_closed_message(channel)
      "WhatsApp's 24-hour customer service window is closed for #{channel.phone_number_e164} — " \
        "only a pre-approved template (#send_template) can be sent until the guest messages in again."
    end

    def post(channel, payload)
      # Checked here rather than in the constructor so that building a
      # provider is always safe — the app boots, and every hotel's QR web
      # chat works, with no WhatsApp token configured at all. Mirrors
      # Ai::Client#chat's identical guard around ANTHROPIC_API_KEY.
      if access_token.blank?
        raise ApiError.new(
          "WHATSAPP_ACCESS_TOKEN is not set — WhatsApp cannot send. " \
          "See .env.example (local) or render.yaml (production)."
        )
      end

      uri = URI("#{BASE_URL}/#{api_version}/#{channel.phone_number_id}/messages")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{access_token}"
      request["Content-Type"] = "application/json"
      request.body = payload.to_json

      handle(http.request(request))
    end

    def handle(response)
      status = response.code.to_i

      case status
      when 200..299
        JSON.parse(response.body).dig("messages", 0, "id")
      when 401
        raise AuthenticationError, error_message(response)
      when 429
        raise RateLimitedError.new(error_message(response), retry_after: retry_after_from(response))
      else
        raise ApiError.new(error_message(response), status: status)
      end
    end

    # Meta's own error envelope: {"error": {"message": ..., "type": ...,
    # "code": ...}}. Falls back to the raw body for a response that is not
    # JSON at all (a proxy timeout page, for instance) rather than raising a
    # second, more confusing exception out of the rescue path itself.
    def error_message(response)
      JSON.parse(response.body).dig("error", "message").presence || response.body
    rescue JSON::ParserError
      response.body
    end

    # Meta sends `retry-after` in seconds on a 429 when it has advice to
    # give; absent on some responses, hence the nil-safety — a caller must
    # read nil as "no advice", never as "retry now".
    def retry_after_from(response)
      response["retry-after"].presence&.to_i
    end
  end
end
