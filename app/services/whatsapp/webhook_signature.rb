module Whatsapp
  # HMAC-SHA256 over the raw request body — Meta's own scheme for proving a
  # webhook delivery genuinely came from them (documented at
  # https://developers.facebook.com/docs/graph-api/webhooks/getting-started#validate-payloads).
  # The one place this app computes or compares that signature: shared by
  # Webhooks::WhatsappController (the real gate — a bad signature never
  # reaches the database) and config/initializers/rack_attack.rb (the
  # safelist exemption for already-verified deliveries), so there is exactly
  # one implementation of "is this request really from Meta," not two that
  # can quietly drift apart.
  #
  # Takes plain strings, never an ActionDispatch::Request or a Rack::Request:
  # the controller calls this with request.raw_post specifically — Rails has
  # already parsed and reordered the JSON by the time params exists, so
  # signing *that* would verify something the sender never sent — and
  # Rack::Attack's own request wrapper reads the raw Rack input directly, one
  # layer below where ActionDispatch::Request exists at all. Neither caller
  # has to teach this class its own HTTP framework.
  class WebhookSignature
    PREFIX = "sha256="

    def self.valid?(raw_body:, signature_header:, secret: Rails.configuration.x.whatsapp.app_secret)
      return false if secret.blank? || signature_header.blank?
      return false unless signature_header.start_with?(PREFIX)

      expected = PREFIX + OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body.to_s)

      # secure_compare, not ==: a naive == on two strings short-circuits at
      # the first mismatched byte, so its running time leaks how many
      # leading bytes of a guess were already correct — the textbook timing
      # side-channel an HMAC exists to close. secure_compare still leaks the
      # *length* of a mismatch (it bails out immediately on a bytesize
      # difference, documented in ActiveSupport::SecurityUtils itself) but
      # never leaks anything about *content*, which is the guarantee that
      # actually matters for a fixed-length hex digest like this one.
      ActiveSupport::SecurityUtils.secure_compare(signature_header, expected)
    end
  end
end
