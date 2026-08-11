module Whatsapp
  # One stored webhook delivery, turned into a hotel, a guest and a message —
  # and then handed to exactly the same pipeline a web guest's message goes
  # through. Nothing downstream of here knows or cares which channel a
  # message arrived on: translation, the concierge, service requests, the
  # reception inbox and the request board were all built channel-agnostic in
  # Slices 2–5, and keeping them that way is the whole point of this slice
  # (see docs/plan/slice-6-tasks.md's opening note).
  #
  # Runs with **no ambient tenant**. That is not an oversight — it is this
  # class's defining constraint: the payload's own phone_number_id is what
  # discovers the hotel, so the first lookup has to happen before one exists
  # (WhatsappChannel.route, the only tenant-free query here), and everything
  # after it runs inside ActsAsTenant.with_tenant.
  #
  # **Nothing here raises past #route!.** Meta was answered 200 the moment
  # Webhooks::WhatsappController stored the delivery, so an exception escaping
  # this class cannot reach Meta and cannot make it retry — it would only
  # fill the failed-jobs table with something a human has to read out of a
  # stack trace instead of out of a webhook_events row. The row is the
  # durable record: it ends `processed`, `ignored` or `failed` (with #error),
  # and re-running the job on it is always safe.
  class InboundRouter
    def initialize(webhook_event)
      @event = webhook_event
      @hotels = []
      @handled = 0
    end

    def route!
      Provider.parser_for(event.provider).parse_webhook(event.payload).each { |batch| route_batch(batch) }

      settle!
    rescue StandardError => e
      # Deliberately broad. Every specific failure below is already handled;
      # anything reaching here is a bug or an infrastructure problem, and the
      # only useful outcome is a row that says so and an alert that names it.
      Sentry.capture_exception(e)
      event.update!(status: :failed, error: "#{e.class}: #{e.message}".truncate(1000))
    end

    private
      attr_reader :event, :hotels, :handled

      def route_batch(batch)
        channel = WhatsappChannel.route(batch.phone_number_id)
        return report_unroutable(batch) if channel.nil?

        hotel = channel.hotel
        # A suspended hotel refuses guests on every web request (see
        # Guest::BaseController); there is no reason WhatsApp should be the
        # one door left open. A disabled channel is a hotel deliberately
        # switching this number off. `pending` is NOT refused: a channel is
        # pending from registration until someone confirms it works, and the
        # message that confirms it works arrives on it.
        return if hotel.nil? || hotel.suspended? || channel.disabled?

        hotels << hotel
        ActsAsTenant.with_tenant(hotel) { process(batch, channel) }
      end

      def process(batch, channel)
        channel.update_column(:last_inbound_at, Time.current) if batch.messages.any?

        batch.messages.each { |message| deliver(message) }
        batch.statuses.each { |status| apply(status) }
      end

      # The guest's message, on the one path every guest message in this app
      # takes. Conversation#post_guest_message! is what stamps the 24-hour
      # window anchor, broadcasts to the reception inbox, enqueues the
      # translation and enqueues the concierge — none of which this class
      # repeats, because a second copy of that sequence is a second copy that
      # can drift.
      def deliver(inbound)
        return unhandled_type(inbound) unless inbound.text?

        session = GuestSession.for_whatsapp(
          phone_e164: e164(inbound.wa_id),
          name: inbound.profile_name.presence || e164(inbound.wa_id),
          accepted_at: inbound.timestamp
        )
        # A hotel that has blocked this guest has already answered. Nothing is
        # written and nothing is replied to — the same silence Guest::
        # BaseController gives a blocked session on the web.
        return unless session.active?

        Conversation.live_for(session).post_guest_message!(
          body: inbound.text.truncate(Message::MAX_BODY_LENGTH),
          external_id: inbound.provider_message_id
        )
        @handled += 1
      end

      # Meta's own delivery receipts for messages *this app* sent (Slice 6
      # Task 4 is what starts producing the external_ids they match on, so
      # today they will usually find nothing — which is correct, not a bug).
      #
      # Out-of-order callbacks are ordinary on WhatsApp: a `read` genuinely
      # can arrive before its `delivered`. Message#apply_delivery_status! is
      # where the refusal to move backwards lives, in one place, so this
      # method cannot develop a second opinion about it.
      def apply(status)
        message = Message.find_by(external_id: status.provider_message_id)
        # A callback for a message this hotel does not have. Not an error:
        # the delivery could belong to a message deleted with its
        # conversation, or predate this app's own records.
        return if message.nil?

        @handled += 1 if message.apply_delivery_status!(status)
      end

      # Images, locations, voice notes, contacts, stickers. Out of scope for
      # this slice by design (see Whatsapp::InboundMessage), and deliberately
      # *not* written into the transcript with an invented placeholder body:
      # what a receptionist should see for "the guest sent a photo" is a copy
      # decision with four locales behind it, not something to guess at here.
      # Logged rather than reported to Sentry — a guest sending a photo is
      # normal behaviour this slice cannot serve yet, not a fault.
      def unhandled_type(inbound)
        Rails.logger.info(
          "[whatsapp] ignoring inbound #{inbound.type.inspect} message #{inbound.provider_message_id} " \
          "— only text is handled in this slice"
        )
      end

      def report_unroutable(batch)
        Sentry.capture_exception(
          UnroutableDelivery.new(
            "no WhatsApp channel is registered for phone_number_id #{batch.phone_number_id.inspect} — " \
            "guest messages on that number are being dropped"
          )
        )
      end

      # Meta sends wa_id without a leading +. Stored as-is it would never
      # match the E.164 number Task 4 sends back *to*, and phonelib (already
      # this app's phone authority — see WhatsappChannel) is what knows which
      # country codes and lengths really exist. A number it cannot parse is
      # kept verbatim with a + in front rather than dropped: an unusual number
      # is still a guest.
      def e164(wa_id)
        candidate = wa_id.to_s.start_with?("+") ? wa_id.to_s : "+#{wa_id}"

        Phonelib.parse(candidate).e164.presence || candidate
      end

      # `processed` means at least one thing in this delivery actually landed.
      # `ignored` covers every "parsed fine, had nowhere to go" case at once —
      # an unknown number, a suspended hotel, a blocked guest, a message type
      # this slice does not handle, a template-approval callback — which is
      # exactly what WebhookEvent's own enum says that status is for.
      #
      # hotel_id is filled in only when one hotel owns the whole delivery.
      # A batched payload spanning two hotels has no single owner, and naming
      # whichever was parsed first would be a half-truth on the one row a
      # person reads to find out what happened.
      def settle!
        owner = hotels.uniq
        event.update!(
          status: handled.positive? ? :processed : :ignored,
          hotel_id: (owner.first.id if owner.one?)
        )
      end
  end
end
