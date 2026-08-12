module Retention
  # The nightly sweep that makes Retention::Policy true.
  #
  # Everything about what is kept and for how long lives in that file; this
  # one only knows how to apply it. If you are here to answer "why did this
  # row go", read the policy — the answer is not in this job.
  #
  # **Hotel by hotel, inside a tenant block each time**, the same shape
  # Ai::TranslationWatchdogJob and ServiceRequests::ExpireDraftsJob already
  # use, and for the reason ExpireDraftsJob spells out in full: a maintenance
  # job that spans hotels is exactly the code where a tenant-less query looks
  # harmless, and this one *deletes*. The one part that legitimately runs
  # outside the loop is `webhook_events`, and it says why below.
  #
  # **In batches**, because the first run against a database with a year of
  # history is the largest delete this app will ever do, and holding one
  # transaction open across all of it would block every writer behind it for
  # as long as it took. Each batch is its own statement; a run interrupted
  # half way has simply done less work, and the next run finishes it.
  class PurgeExpiredGuestDataJob < ApplicationJob
    include TenantFree

    queue_as :low

    # Small enough that no single statement locks a table for long, large
    # enough that a busy hotel's month of chat is a handful of round trips.
    BATCH_SIZE = 500

    def perform
      chat_cutoff = Policy.guest_chat_cutoff
      operational_cutoff = Policy.operational_cutoff

      Hotel.find_each do |hotel|
        ActsAsTenant.with_tenant(hotel) { purge_hotel(hotel, chat_cutoff, operational_cutoff) }
      end

      purge_webhook_events
    end

    private
      # Both cutoffs are read once, before the loop, and passed down: a run
      # over a hundred hotels takes minutes, and a job that recomputed
      # "90 days ago" per hotel would apply a slightly different policy to
      # the last one than to the first.
      def purge_hotel(hotel, chat_cutoff, operational_cutoff)
        anonymize_old_service_requests(hotel, chat_cutoff)
        redact_old_question_originals(hotel, chat_cutoff)
        delete_silent_conversations(hotel, chat_cutoff)
        delete_expired_guest_sessions(hotel, chat_cutoff)
        delete_old_service_requests(hotel, operational_cutoff)
        delete_old_ai_runs(hotel, operational_cutoff)
      end

      # Ordered before the deletions on purpose. Nothing depends on it — the
      # cascade would null the same two foreign keys anyway — but a request
      # anonymized while its conversation is still there is one that can be
      # checked by hand against what it used to say, and the alternative
      # ordering can only be verified against rows that no longer exist.
      def anonymize_old_service_requests(hotel, cutoff)
        hotel.service_requests.identifiable.where(created_at: ...cutoff)
          .in_batches(of: BATCH_SIZE) { |batch| batch.anonymize_all! }
      end

      # The row itself is the hotel's own knowledge backlog and is kept (see
      # the policy). `question_original` is one guest's literal sentence and
      # is not.
      def redact_old_question_originals(hotel, cutoff)
        hotel.unanswered_questions.where.not(question_original: nil).where(created_at: ...cutoff)
          .in_batches(of: BATCH_SIZE) { |batch| batch.update_all(question_original: nil) }
      end

      # Anchored on the conversation's own last message rather than on its
      # guest session, because a WhatsApp identity is renewed every time the
      # guest writes (GuestSession#renew_for_whatsapp!) — so a guest who
      # comes back every few months has a session that never expires, and a
      # sweep that only looked at sessions would keep their first
      # conversation forever.
      #
      # COALESCE, because last_message_at is null for a conversation nobody
      # ever wrote in, and `NULL < cutoff` is not true — those would be the
      # rows that never got purged, which is precisely the shape of bug that
      # goes unnoticed for a year.
      #
      # delete_all, not destroy_all: messages and drafts go with it through
      # ON DELETE CASCADE, service_requests.conversation_id and
      # ai_runs.conversation_id are nulled by the same foreign keys, and
      # loading a hundred thousand conversations into Ruby to run callbacks
      # that only broadcast to a page nobody is looking at would be slower
      # and no safer.
      def delete_silent_conversations(hotel, cutoff)
        hotel.conversations.where("COALESCE(last_message_at, conversations.created_at) < ?", cutoff)
          .in_batches(of: BATCH_SIZE) { |batch| batch.delete_all }
      end

      # The identity itself, once the stay it represents has been over for a
      # full retention window. Takes any conversations still hanging off it
      # with it, by the same cascade.
      def delete_expired_guest_sessions(hotel, cutoff)
        hotel.guest_sessions.where(expires_at: ...cutoff)
          .in_batches(of: BATCH_SIZE) { |batch| batch.delete_all }
      end

      # request_events go with them by cascade — they are meaningless
      # without the request they describe.
      def delete_old_service_requests(hotel, cutoff)
        hotel.service_requests.where(created_at: ...cutoff)
          .in_batches(of: BATCH_SIZE) { |batch| batch.delete_all }
      end

      def delete_old_ai_runs(hotel, cutoff)
        hotel.ai_runs.where(created_at: ...cutoff)
          .in_batches(of: BATCH_SIZE) { |batch| batch.delete_all }
      end

      # Outside the per-hotel loop, and that is not an oversight.
      # `webhook_events` is this app's one deliberately non-tenant-scoped
      # table: a delivery is stored before anything knows which hotel it
      # belongs to, and `hotel_id` stays null for one that never routed —
      # an unknown phone_number_id, or a batched payload spanning two hotels
      # with no single owner. Those rows carry a real phone number and a real
      # message, and a loop over hotels would never reach a single one of
      # them.
      def purge_webhook_events
        WebhookEvent.where(created_at: ...Policy.webhook_event_cutoff)
          .in_batches(of: BATCH_SIZE) { |batch| batch.delete_all }
      end
  end
end
