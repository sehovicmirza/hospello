module Whatsapp
  # The critical-queue home for turning one stored WebhookEvent into routed,
  # persisted guest activity. Routing (payload -> metadata.phone_number_id ->
  # WhatsappChannel -> hotel), guest identity, and the concierge handoff are
  # Slice 6 Task 3's job (Whatsapp::InboundRouter, not built yet) — this file
  # exists now, ahead of that task, only because Webhooks::WhatsappController
  # (Slice 6 Task 2) has to enqueue *something* the moment it durably stores a
  # new webhook_events row: "insert, enqueue, return 200" is this app's whole
  # answer to "be fast and let a background job do the work," and that
  # promise is only real if the class it names actually exists and can be
  # performed safely today.
  #
  # queue: critical, never :ai — the same reasoning GenerateReplyJob's own
  # queue: :ai documents from the other side: a guest's very first WhatsApp
  # message must never queue behind a slow upstream LLM call, so this job
  # (and everything Task 3 adds to it) stays off that queue entirely. See
  # config/queue.yml's own comment on the critical worker pool.
  #
  # TenantFree, not tenant-scoped: no hotel is known yet when this is
  # enqueued — routing is what discovers one (see WebhookEvent's own class
  # comment on why webhook_events itself carries no ambient tenant). Without
  # this, ApplicationJob's around_perform would raise
  # ActsAsTenant::Errors::NoTenantSet on every single run, since a bare
  # Integer id is neither a Hotel nor something that answers #hotel_id.
  class ProcessInboundJob < ApplicationJob
    include TenantFree

    queue_as :critical

    # Deliberately a no-op until Slice 6 Task 3 builds Whatsapp::InboundRouter
    # and gives this a real body. Nothing is lost by leaving a webhook_event
    # row `received` in the meantime: Webhooks::WhatsappController::receive
    # only ever calls this after the row is already durably committed, so
    # there is no work in flight here that a currently-empty #perform could
    # drop.
    def perform(webhook_event_id)
    end
  end
end
