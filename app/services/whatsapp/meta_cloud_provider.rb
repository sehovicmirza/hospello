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

    # --- Inbound: Meta's webhook envelope, normalized -------------------------
    #
    # https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/payload-examples
    #
    #   entry[].changes[].value.metadata.phone_number_id  — routes to a hotel
    #   entry[].changes[].value.messages[]                — inbound messages
    #   entry[].changes[].value.contacts[]                — profile names, by wa_id
    #   entry[].changes[].value.statuses[]                — delivery callbacks
    #
    # Both `entry` and `changes` are plural in Meta's own schema and really
    # can carry more than one — including for different phone_number_ids,
    # which in this app means different *hotels*. Reading only the first of
    # each would silently drop another hotel's guest, so every one is parsed
    # into its own Whatsapp::InboundBatch.
    #
    # Nothing in here raises. A payload shape this app has never seen simply
    # produces fewer batches (or an empty one) — see Whatsapp::Provider
    # .parse_webhook for why that is a requirement and not merely defensive.
    class << self
      def parse_webhook(payload)
        Array(payload.try(:[], "entry")).flat_map do |entry|
          Array(entry.try(:[], "changes")).filter_map { |change| batch_from(change) }
        end
      end

      private
        def batch_from(change)
          value = change.try(:[], "value")
          return nil unless value.is_a?(Hash)

          phone_number_id = value.dig("metadata", "phone_number_id").presence
          # Nothing to route it by. Meta always sends this on the
          # subscriptions this app registers for; a change without it is a
          # shape we have no answer for, and guessing a hotel is the single
          # worst thing this file could do.
          return nil if phone_number_id.blank?

          InboundBatch.new(
            phone_number_id: phone_number_id,
            messages: messages_from(value, phone_number_id),
            statuses: statuses_from(value)
          )
        end

        def messages_from(value, phone_number_id)
          names = profile_names_from(value)

          Array(value["messages"]).filter_map do |message|
            next unless message.is_a?(Hash)

            wa_id = message["from"].presence
            provider_message_id = message["id"].presence
            # No id means nothing to dedupe on, and messages.external_id's
            # unique index is the only thing standing between a Meta retry
            # and a guest's message appearing twice in their own transcript.
            next if wa_id.blank? || provider_message_id.blank?

            InboundMessage.new(
              phone_number_id: phone_number_id,
              wa_id: wa_id,
              type: message["type"].to_s,
              text: message.dig("text", "body"),
              timestamp: time_from(message["timestamp"]),
              provider_message_id: provider_message_id,
              profile_name: names[wa_id]
            )
          end
        end

        # contacts[] is a *sibling* of messages[], not nested inside it —
        # matched back to a message by wa_id.
        def profile_names_from(value)
          Array(value["contacts"]).each_with_object({}) do |contact, names|
            next unless contact.is_a?(Hash)

            wa_id = contact["wa_id"].presence
            names[wa_id] = contact.dig("profile", "name").presence if wa_id
          end
        end

        def statuses_from(value)
          Array(value["statuses"]).filter_map do |status|
            next unless status.is_a?(Hash)

            provider_message_id = status["id"].presence
            next if provider_message_id.blank?

            DeliveryStatus.new(
              provider_message_id: provider_message_id,
              status: status["status"].to_s,
              timestamp: time_from(status["timestamp"]),
              error: error_from(status)
            )
          end
        end

        # Meta's own errors[] on a failed status: {"code": 131047, "title":
        # "Re-engagement message"}. Kept as one readable line because its
        # only consumer is a receptionist being told why a reply did not
        # arrive — see Slice 6 Task 4.
        def error_from(status)
          error = Array(status["errors"]).first
          return nil unless error.is_a?(Hash)

          [ error["code"], error["title"].presence || error["message"].presence ].compact.join(": ").presence
        end

        # Unix seconds, sent as a String. Anything else (absent, empty, not a
        # number) becomes nil rather than 1970 — a caller reading nil knows
        # it has no time; a caller reading the epoch believes a wrong one.
        def time_from(raw)
          seconds = Integer(raw.to_s, exception: false)
          seconds && Time.zone.at(seconds)
        end
    end

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
