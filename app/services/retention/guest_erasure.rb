module Retention
  # One named person, asking to be forgotten, now.
  #
  # A different operation from the nightly purge in three ways, and each one
  # changes the design:
  #
  #   - **It is immediate.** Nobody asking to be erased is told "within 90
  #     days, when the sweep next passes your row".
  #   - **It is for one identity**, so it runs in a transaction: either the
  #     erasure happened and was recorded, or neither. The purge deliberately
  #     does the opposite, because it must not hold a transaction open across
  #     the largest delete this app ever does.
  #   - **It has to be auditable.** The one record that must survive an
  #     erasure is the fact that it happened — and it has to prove that
  #     without recreating the very thing it destroyed, which is why the
  #     audit entry carries ids and counts and never a name or a number.
  #
  # **What is deleted and what is anonymized** follows the same line the
  # policy draws for the scheduled purge, for the same reason: a transcript
  # is the guest's data and goes; a completed service request is also the
  # hotel's operational record of work its staff did, so the row stays and
  # the guest comes out of it (ServiceRequest.anonymize_all! names every
  # column).
  #
  # **Identity here is one guest session**, not "a person across every stay".
  # This app deliberately has no cross-stay guest record — a returning guest
  # is a new session, which is itself a privacy property rather than a
  # limitation. So an individual with two stays has two identities to erase,
  # and Platform::GuestErasuresController's list is what makes them findable
  # rather than a hidden second row somebody forgets.
  class GuestErasure
    # What is about to be destroyed, or what just was. The confirmation
    # screen and the audit entry are built from the same object, computed by
    # the same scopes the erasure itself uses — a confirmation that named
    # what it was about to destroy from a different query than the one that
    # destroys it is a confirmation that can be wrong.
    Tally = Data.define(:conversations, :messages, :service_requests, :knowledge_gaps, :webhook_events)

    def self.preview(guest_session:) = new(guest_session).preview

    def self.call(guest_session:, actor:) = new(guest_session).erase!(actor: actor)

    def initialize(guest_session)
      @guest_session = guest_session
      @hotel = guest_session.hotel
    end

    def preview
      in_tenant do
        Tally.new(
          conversations: conversations.count,
          messages: messages.count,
          service_requests: service_requests.count,
          knowledge_gaps: knowledge_gaps.count,
          webhook_events: webhook_events.count
        )
      end
    end

    # @return [Tally] what was destroyed
    def erase!(actor:)
      in_tenant do
        tally = preview

        ActiveRecord::Base.transaction do
          service_requests.anonymize_all!
          knowledge_gaps.update_all(question_original: nil)
          webhook_events.delete_all
          # Last, and the reason the counts above were taken first: this one
          # takes the conversations and every message in them with it,
          # through ON DELETE CASCADE.
          guest_session.destroy!
          record_audit(actor, tally)
        end

        tally
      end
    end

    private
      attr_reader :guest_session, :hotel

      def in_tenant(&block) = ActsAsTenant.with_tenant(hotel, &block)

      def conversations = hotel.conversations.where(guest_session_id: guest_session.id)

      def messages = hotel.messages.where(conversation_id: conversations.select(:id))

      # Only the ones that still have a guest in them: a request erased for
      # somebody else, or already caught by the nightly sweep, is not part of
      # what this erasure destroys and must not be counted as if it were.
      def service_requests
        hotel.service_requests.identifiable.where(guest_session_id: guest_session.id)
      end

      # The generalized question stays — it is a fact about what this hotel
      # has not written down, and its `asked_count` is the sum of every guest
      # who hit the same gap, not this one's. `question_original` is this
      # guest's own sentence, and goes.
      def knowledge_gaps
        hotel.unanswered_questions.where.not(question_original: nil)
          .where(conversation_id: conversations.select(:id))
      end

      # The raw Meta payload carries the guest's number, their WhatsApp
      # profile name and the text of what they wrote, and it is the one place
      # none of the tenant-scoped deletions above would reach.
      #
      # Matched on the phone number's digits against the whole payload rather
      # than on a parsed field, because the payload shape is Meta's and this
      # has to keep working when it changes. Over-matching is close to
      # harmless here — a webhook_events row is an idempotency record for a
      # delivery already handled, and Conversation#post_guest_message! dedupes
      # on Meta's own message id globally, so even a replay of a row deleted
      # by accident cannot produce a second message.
      #
      # **Scoped to this hotel**, so an erasure at one hotel never destroys
      # another hotel's record of the same person writing to *them*. The
      # residual: a delivery that never routed, or one batched across two
      # hotels, has no hotel_id and is left to its own 30-day window (see
      # Retention::Policy). Stated rather than silently worked around — the
      # alternative is a platform admin at one hotel reaching into another's
      # data, which is a worse answer than "complete within a month".
      def webhook_events
        digits = guest_session.phone_e164.to_s.gsub(/\D/, "")
        return WebhookEvent.none if digits.blank?

        WebhookEvent.where(hotel_id: hotel.id).where("payload::text LIKE ?", "%#{digits}%")
      end

      # Names nobody. The guest session's id is enough to answer "did you
      # action my request" — anything more and the proof of an erasure would
      # be a copy of what it erased, sitting in a table this policy keeps
      # forever on purpose.
      def record_audit(actor, tally)
        AuditLog.record!(
          actor: actor, hotel: hotel, action: "guest_data.erase",
          metadata: {
            "guest_session_id" => guest_session.id,
            "channel" => guest_session.channel,
            "conversations" => tally.conversations,
            "messages" => tally.messages,
            "service_requests_anonymized" => tally.service_requests,
            "knowledge_gaps_redacted" => tally.knowledge_gaps,
            "webhook_events_deleted" => tally.webhook_events
          }
        )
      end
  end
end
