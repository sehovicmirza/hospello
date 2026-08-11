# Every WhatsApp/Meta Cloud credential and config value the app reads,
# resolved once at boot — mirrors config/initializers/ai.rb exactly, and for
# the same reason: a credential or API version scattered as ENV[...] calls
# through the services layer is a grep away from a bug the day it changes;
# one file is not.
#
# Nothing here is required for the app to boot, or for any hotel to use the
# QR web chat — WhatsApp (Slice 6) is a second, optional channel. With
# WHATSAPP_ACCESS_TOKEN unset, Whatsapp::MetaCloudProvider raises a clear
# Whatsapp::ApiError the moment something asks it to send, exactly as
# Ai::Client does with no ANTHROPIC_API_KEY configured.
Rails.application.configure do
  # One token for the whole app, not per hotel: Hospello is the Meta Tech
  # Provider and this system-user token can send on behalf of every hotel's
  # phone_number_id it has been granted access to (see
  # docs/whatsapp-onboarding.md) — which is also why whatsapp_channels has
  # no access_token column of its own.
  #
  # `.presence` for the same reason config.x.ai.api_key uses it: an unfilled
  # Render field and a blank `.env` line both produce an empty string, and
  # that must read as absent, not as a token that will fail authentication
  # at runtime.
  config.x.whatsapp.access_token = ENV["WHATSAPP_ACCESS_TOKEN"].presence

  # Meta deprecates each Graph API version roughly two years after release,
  # so this is a config default rather than a hardcoded constant in the
  # adapter — bumping it is one environment variable, not a deploy.
  config.x.whatsapp.api_version = ENV.fetch("WHATSAPP_API_VERSION", "v22.0")

  # Slice 6 Task 2 — the webhook's two secrets. Neither is the access token
  # above: that authenticates *this app* to Meta when *sending*; these
  # authenticate Meta to *this app* when *receiving*, and come from a
  # different place in Meta's dashboard (the App's own Settings > Basic, not
  # the WhatsApp product's API setup).
  #
  # The Meta App Secret. Whatsapp::WebhookSignature HMAC-SHA256s the raw
  # body of every inbound webhook with this and compares it, in constant
  # time, against the X-Hub-Signature-256 header Meta sends — the only
  # thing standing between this app's one unauthenticated public endpoint
  # and a forged request. `.presence`, same reasoning as access_token above:
  # blank must read as absent, not as a secret every signature will fail
  # against. Blank is the fail-closed default — see WebhookSignature.valid?,
  # which refuses to verify anything (never "trusts" a request) when this
  # is unset.
  config.x.whatsapp.app_secret = ENV["WHATSAPP_APP_SECRET"].presence

  # A string this app makes up and enters into Meta's dashboard when
  # registering the webhook URL; Meta echoes it straight back on the GET
  # handshake that verifies the URL is real (hub.verify_token). Not a
  # secret Meta generates — just a shared value proving whoever configured
  # the webhook in Meta's dashboard is the same party running this app.
  # Also compared with secure_compare (Webhooks::WhatsappController#verify)
  # for the same reason app_secret is: it costs nothing to hold both
  # attacker-facing comparisons to the same standard.
  config.x.whatsapp.webhook_verify_token = ENV["WHATSAPP_WEBHOOK_VERIFY_TOKEN"].presence
end
