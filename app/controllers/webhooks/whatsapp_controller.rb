module Webhooks
  # Meta's inbound door for every hotel's WhatsApp channel at once. The
  # payload's own metadata.phone_number_id (Slice 6 Task 3) is what
  # eventually decides which hotel a delivery belongs to — this controller
  # itself never takes a hotel from the URL, a param, or a session, because
  # there is no guest or staff person on the other end of this connection,
  # only Meta's servers.
  #
  # Deliberately does NOT inherit ApplicationController. That module bundles
  # three things that make no sense for a server-to-server JSON callback and
  # would only add risk here:
  #   - Authentication's before_action would redirect every delivery to a
  #     sign-in page that does not exist for Meta.
  #   - Pundit::Authorization has nothing to authorize against — there is no
  #     current_user, because there is no user.
  #   - allow_browser versions: :modern gates access on whether the
  #     User-Agent parses as a recent Safari/Chrome/Firefox/Opera — a
  #     question with no defensible answer for a webhook, and one this
  #     endpoint's availability should never depend on.
  # ActionController::Base's own CSRF protection (protect_from_forgery with:
  # :exception, switched on for the whole app by
  # config.action_controller.default_protect_from_forgery — set at the
  # ActionController::Base level, not ApplicationController's, so it applies
  # here regardless of ancestry) is still active by default and is skipped
  # explicitly below, deliberately, rather than never having existed: this
  # request carries no session cookie for a CSRF token to protect in the
  # first place, and Meta's own request has no such token to send.
  #
  # Forgery is guarded by a different, stronger mechanism entirely — see
  # Whatsapp::WebhookSignature, the one place this app computes or compares
  # the HMAC-SHA256 signature Meta signs every delivery with.
  class WhatsappController < ActionController::Base
    skip_before_action :verify_authenticity_token

    # GET — Meta's subscription handshake, sent once when this URL is
    # registered (or re-verified) in the App dashboard's Webhooks product.
    # Not a delivery: no signature, no JSON body, just three query params.
    # https://developers.facebook.com/docs/graph-api/webhooks/getting-started#verification-requests
    def verify
      if hub_mode_is_subscribe? && verify_token_matches?
        render plain: params["hub.challenge"].to_s
      else
        head :forbidden
      end
    end

    # POST — a real delivery: one or more messages or status updates,
    # batched under Meta's own envelope. Must answer fast, and with a 2xx
    # exactly once the delivery is durably recorded — Meta retries anything
    # slow or non-200, so a slow or failing handler here turns one guest
    # message into a retry storm. Interpreting what was received (routing to
    # a hotel, creating a guest, replying) is deliberately NOT this method's
    # job — see WebhookEvent's own class comment for why storing it is step
    # one and Slice 6 Task 3 owns everything after.
    def receive
      raw_body = request.raw_post

      return head(:unauthorized) unless signature_verified?(raw_body)

      enqueue_processing_for(JSON.parse(raw_body))
      head :ok
    rescue JSON::ParserError => e
      # A signature-verified body that still isn't valid JSON cannot be a
      # real Meta Cloud API delivery (its payloads are always JSON) — and
      # any retry would resend the exact same unparseable bytes, so a 500
      # here would just make Meta retry something that will never succeed,
      # exactly what this app's "never raise on a malformed webhook" rule
      # exists to prevent. There is no message or status id to store or
      # dedupe on, so no WebhookEvent row is written for it — report it and
      # answer 200 anyway.
      Sentry.capture_exception(e)
      head :ok
    end

    private
      def hub_mode_is_subscribe?
        params["hub.mode"] == "subscribe"
      end

      # secure_compare here too, even though the brief's constant-time
      # requirement is written specifically about the delivery signature:
      # this is also a shared-secret comparison against attacker-supplied
      # input (anyone can GET this URL and try tokens), and there is no
      # reason to hold it to a weaker standard than its neighbor.
      def verify_token_matches?
        configured = Rails.configuration.x.whatsapp.webhook_verify_token.to_s
        supplied = params["hub.verify_token"].to_s

        configured.present? && ActiveSupport::SecurityUtils.secure_compare(supplied, configured)
      end

      def signature_verified?(raw_body)
        Whatsapp::WebhookSignature.valid?(
          raw_body: raw_body,
          signature_header: request.headers["X-Hub-Signature-256"]
        )
      end

      # Insert-or-skip, then resolve the row's id either way: a fresh
      # RETURNING id on the delivery that wins the race, a plain indexed
      # lookup on a replay Postgres skipped via ON CONFLICT DO NOTHING (see
      # WebhookEvent's unique index on [provider, external_id]). A job is
      # enqueued for every delivery this method sees, not only the first
      # one that happens to insert: if the process died between a first
      # delivery's insert and its enqueue, a Meta retry is the only thing
      # that can recover it, and "replay is harmless" has to mean
      # recoverable, not merely deduplicated at the row level. Whatever
      # Slice 6 Task 3's job does with a row it has already finished
      # processing is that job's own idempotency to keep — the same way
      # messages.external_id's own unique index backstops a duplicate
      # enqueue one layer further downstream.
      def enqueue_processing_for(payload)
        external_id = external_id_for(payload)
        result = WebhookEvent.insert_all(
          [ { provider: WebhookEvent.providers[:meta_cloud], external_id: external_id, payload: payload } ],
          unique_by: %i[provider external_id]
        )

        id = result.rows.first&.first
        id ||= WebhookEvent.where(provider: :meta_cloud, external_id: external_id).pick(:id)

        Whatsapp::ProcessInboundJob.perform_later(id) if id
      end

      # Meta's own documented nesting
      # (https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/payload-examples):
      # entry[].changes[].value.messages[] for an inbound message,
      # .statuses[] for a delivery-status callback. Reads only the first of
      # each — the id only has to be *a* stable identifier for this
      # delivery, not a complete parse of it, which is deliberately Slice 6
      # Task 3's Whatsapp::InboundRouter's job, not this method's. A payload
      # with neither shape (a template-status-update callback, an account
      # alert, anything this app has never seen) falls back to a hash of the
      # raw body — still stable across retries of the exact same delivery,
      # and still satisfies external_id's NOT NULL constraint. This method's
      # only job is "never leave a delivery with nothing to dedupe on," not
      # "understand what this delivery means."
      def external_id_for(payload)
        entry = Array(payload["entry"]).first || {}
        change = Array(entry["changes"]).first || {}
        value = change["value"] || {}

        Array(value["messages"]).first&.dig("id") ||
          Array(value["statuses"]).first&.dig("id") ||
          Digest::SHA256.hexdigest(payload.to_json)
      end
  end
end
