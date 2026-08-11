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

    # Takes an id rather than the record itself: ActiveJob would have to
    # serialize a WebhookEvent through GlobalID, and this row is written by
    # insert_all (bypassing every Rails callback) at the one moment the app
    # must be fastest — see Webhooks::WhatsappController#enqueue_processing_for,
    # which resolves the id and nothing else.
    #
    # A row that has vanished is not an error worth raising over: the only
    # thing that deletes one is a retention sweep, and a job for a delivery
    # nobody keeps records of any more has nothing to do.
    def perform(webhook_event_id)
      event = WebhookEvent.find_by(id: webhook_event_id)
      return if event.nil?

      InboundRouter.new(event).route!
    end
  end
end
