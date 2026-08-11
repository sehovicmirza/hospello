module Whatsapp
  # One message, out to the guest's phone.
  #
  # This is the first thing in the app that puts text somewhere it cannot be
  # taken back. Everything on the web is a render: the database is the truth
  # and every surface re-reads it, so a mistake is fixed by fixing the row. A
  # WhatsApp message is *sent* — the guest has it, on their own device, and no
  # later correction reaches the copy they already read. Three of the
  # decisions below only make sense in that light.
  #
  # **It waits for the translation.** Ai::TranslateMessageJob deliberately does
  # not block a message on the web (see its class comment and
  # docs/plan/known-issues.md): the overlay arrives a second later into a page
  # that is already showing the words. There is no overlay on WhatsApp. Sending
  # the receptionist's Bosnian first and the guest's German afterwards means
  # the guest receives two messages, one of which they cannot read. So this
  # waits — bounded by the watchdog's own budget, so it always terminates, and
  # when the wait runs out the original goes rather than nothing.
  #
  # **It never sends anything the guest cannot already see.** The guard is
  # `guest_visible?`, the same one Conversation#broadcast_to_guest uses, and
  # internal notes share the messages table with replies. This is the fifth
  # guest-facing read of `messages` in the app and the only one where getting
  # it wrong is unrecoverable.
  class SendMessageJob < ApplicationJob
    queue_as :critical

    # Serialized per conversation for the same reason Ai::GenerateReplyJob is:
    # two replies racing each other would reach the guest's phone in whichever
    # order the network settled, and on this channel that order is final.
    limits_concurrency to: 1, key: ->(message, **) { "wa-send-#{message.conversation_id}" }

    POLL_INTERVAL = 2.seconds

    # Long enough to outlast Ai::TranslationWatchdogJob, which settles any
    # translation still in flight after its own budget — so the wait below is
    # bounded by something that really does happen rather than by hope.
    # Derived from that constant, not copied, so widening one cannot silently
    # strand the other.
    MAX_WAIT = Ai::TranslationWatchdogJob::BUDGET + 5.seconds
    MAX_ATTEMPTS = (MAX_WAIT / POLL_INTERVAL).ceil

    # `provider:` exists so tests can substitute FakeWhatsappProvider; nothing
    # in the app passes it, so ActiveJob is never asked to serialize one. It is
    # deliberately NOT carried across the re-enqueue below — a test that drives
    # the waiting path performs the job itself rather than letting the queue
    # do it, because a fake provider cannot survive serialization and pretending
    # otherwise would hide that.
    def perform(message, provider: nil, attempt: 1)
      @message = message
      @conversation = message.conversation
      @provider = provider

      deliver(attempt)
    end

    private
      attr_reader :message, :conversation, :provider

      # Split from #perform for the reason Ai::GenerateReplyJob's own split
      # documents: keyword arguments there shadow the attr_readers, so a
      # reader silently returns nil and every unit test that injects one
      # passes anyway.
      def deliver(attempt)
        return unless deliverable?

        # Still being translated. Come back rather than sending words the
        # guest cannot read — see the class comment.
        if message.translation_in_flight? && attempt < MAX_ATTEMPTS
          return self.class.set(wait: POLL_INTERVAL).perform_later(message, attempt: attempt + 1)
        end

        # The claim, after the wait: two jobs that both got through the wait
        # race here, and exactly one wins. Anything else has already been sent
        # or is being sent right now.
        return unless message.claim_delivery!

        send_text
      end

      def deliverable?
        return false unless conversation.whatsapp?
        # An internal note is staff commentary. There is no undo on this
        # channel, so this guard is the last one standing between a
        # receptionist's private remark and the guest's phone.
        return false unless message.guest_visible?
        # The guest wrote it; it is already on their own device. Sending it
        # back would read as the hotel repeating them.
        return false if message.guest?

        channel.present? && !channel.disabled? && recipient.present?
      end

      def send_text
        provider_message_id = provider_for(channel).send_text(
          channel: channel, to: recipient, body: body_for_guest, conversation: conversation
        )

        # external_id is the anchor every delivery callback matches on
        # (Whatsapp::InboundRouter#apply). Written in the same statement as the
        # status so a receipt can never arrive for an id nothing has recorded.
        message.update_columns(
          external_id: provider_message_id, delivery_status: Message.delivery_statuses[:sent],
          updated_at: Time.current
        )
        conversation.broadcast_delivery(message)
      rescue WindowClosedError => e
        # Not an error on anyone's part: Meta's rule is that a hotel may only
        # write freely within 24 hours of the guest's last message. The
        # receptionist has to be told, because from their side the reply looks
        # sent — see app/views/staff/conversations/_message.html.erb.
        fail_delivery!(e, report: false)
      rescue RateLimitedError => e
        # Meta is asking us to slow down, not refusing. Re-raised so the queue
        # retries it rather than losing the message; the concurrency limit
        # above keeps a retry behind anything newer for the same conversation.
        Sentry.capture_exception(e)
        raise
      rescue Whatsapp::Error => e
        fail_delivery!(e)
      end

      # What the guest can actually read, decided by the same method the two
      # rendered surfaces use — so "what was sent" and "what the transcript
      # shows" cannot come apart. It falls back to the original whenever there
      # is no usable translation, which is every failure mode at once.
      def body_for_guest
        message.readable_in(conversation.guest_locale).first
      end

      def fail_delivery!(error, report: true)
        Sentry.capture_exception(error) if report
        message.update_columns(
          delivery_status: Message.delivery_statuses[:failed], updated_at: Time.current
        )
        conversation.broadcast_delivery(message)
      end

      def channel = @channel ||= conversation.hotel.whatsapp_channel

      def recipient = conversation.guest_session&.phone_e164

      def provider_for(channel) = provider || Provider.for(channel)
  end
end
