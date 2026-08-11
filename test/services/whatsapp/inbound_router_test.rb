require "test_helper"

module Whatsapp
  # Where a webhook delivery becomes a hotel, a guest and a message.
  #
  # Everything here runs with **no ambient tenant**, deliberately: that is the
  # real state this class is performed in (Whatsapp::ProcessInboundJob is
  # TenantFree — no hotel is known until routing discovers one), and a test
  # that set a tenant up front would prove nothing about the one lookup that
  # has to work without one. `assert_no_tenant` below pins that.
  #
  # The routing tests are the load-bearing ones: phone_number_id is what picks
  # a *hotel*, so getting it wrong routes one hotel's guest into another's
  # dashboard — the single worst failure available in this slice.
  class InboundRouterTest < ActiveSupport::TestCase
    setup do
      @stari = hotels(:stari_grad)
      @vrelo = hotels(:vrelo)
      @stari_channel = with_tenant(@stari) { whatsapp_channels(:stari_grad_whatsapp) }
      @vrelo_channel = with_tenant(@vrelo) { whatsapp_channels(:vrelo_whatsapp) }
      ActsAsTenant.current_tenant = nil
    end

    # --- Routing --------------------------------------------------------------

    test "a delivery routes to the hotel whose phone_number_id it names" do
      route(payload_for(@stari_channel, text: "Dobar dan"))

      message = whatsapp_messages(@stari).sole
      assert_equal @stari, message.hotel
      assert_equal "Dobar dan", message.body
      assert message.guest?
      assert_empty whatsapp_messages(@vrelo)
    end

    test "the router does its lookup with no tenant set — nothing has picked a hotel yet" do
      assert_nil ActsAsTenant.current_tenant, "this suite must not pre-set a tenant"

      route(payload_for(@stari_channel, text: "no tenant here"))

      assert_nil ActsAsTenant.current_tenant, "the router must not leak a tenant back to its caller"
      assert_equal 1, whatsapp_messages(@stari).count
    end

    # The isolation test the brief names explicitly. One character off is not a
    # near miss to be helpfully resolved — it is an unknown number.
    test "a phone_number_id one character off routes nowhere at all, never to the nearest hotel" do
      near_miss = @stari_channel.phone_number_id.sub(/.$/, "X")

      route(payload_for(@stari_channel, text: "close but not this hotel", phone_number_id: near_miss))

      assert_empty whatsapp_messages(@stari)
      assert_empty whatsapp_messages(@vrelo)
      assert @event.reload.ignored?
    end

    test "hotel B's phone_number_id never produces a row belonging to hotel A" do
      route(payload_for(@vrelo_channel, text: "ovo je za Vrelo"))

      assert_equal 0, with_tenant(@stari) { GuestSession.where(channel: :whatsapp).count }
      assert_equal 1, with_tenant(@vrelo) { GuestSession.where(channel: :whatsapp).count }
      assert_equal @vrelo, @event.reload.hotel
    end

    test "an unknown phone_number_id is ignored and reported, never raised" do
      reported = capture_sentry_exceptions do
        route(payload_for(@stari_channel, text: "hello", phone_number_id: "PHONE_NUMBER_ID_NOBODY_HAS"))
      end

      assert @event.reload.ignored?
      assert_nil @event.hotel_id
      assert_equal 1, reported.size
      assert_match "PHONE_NUMBER_ID_NOBODY_HAS", reported.first.message
    end

    # One delivery, two hotels. Meta's envelope is plural at two levels and
    # really can carry both — handling only the first would drop the second
    # hotel's guest entirely.
    test "one delivery naming two hotels reaches both of them" do
      route(two_hotel_payload)

      assert_equal 1, whatsapp_messages(@stari).count
      assert_equal 1, whatsapp_messages(@vrelo).count
      # Two hotels, so no single one owns the row — better nil than a
      # half-truth naming whichever happened to be parsed first.
      assert_nil @event.reload.hotel_id
      assert @event.processed?
    end

    # --- Hotels and channels that must not accept traffic ----------------------

    test "a suspended hotel accepts nothing, the same as on the web" do
      @stari.update!(status: :suspended)

      route(payload_for(@stari_channel, text: "still open?"))

      assert_empty whatsapp_messages(@stari)
      assert @event.reload.ignored?
    end

    test "a deliberately disabled channel accepts nothing" do
      with_tenant(@stari) { @stari_channel.update!(status: :disabled) }

      route(payload_for(@stari_channel, text: "hello?"))

      assert_empty whatsapp_messages(@stari)
      assert @event.reload.ignored?
    end

    # A channel is `pending` from the moment a hotel registers it until someone
    # confirms it works — and the message that confirms it works arrives on it.
    # Refusing pending traffic would make onboarding impossible.
    test "a pending channel still accepts messages — that is how onboarding is confirmed" do
      assert @vrelo_channel.pending?, "fixture drift: vrelo's channel is meant to be pending"

      route(payload_for(@vrelo_channel, text: "prvi test"))

      assert_equal 1, whatsapp_messages(@vrelo).count
    end

    test "an inbound message stamps the channel's last_inbound_at" do
      with_tenant(@stari) { @stari_channel.update!(last_inbound_at: 3.days.ago) }

      route(payload_for(@stari_channel, text: "hello"))

      assert_operator with_tenant(@stari) { @stari_channel.reload.last_inbound_at }, :>, 1.minute.ago
    end

    # --- Identity -------------------------------------------------------------

    test "a first message creates a guest session keyed on the phone number, with no room" do
      route(payload_for(@stari_channel, text: "hello", wa_id: "38761555111"))

      session = with_tenant(@stari) { GuestSession.find_by!(phone_e164: "+38761555111") }
      assert session.whatsapp?
      assert session.unverified?, "a WhatsApp guest is exactly as unverified as a web one"
      assert_nil session.room_id, "a WhatsApp guest starts roomless by design"
      assert_nil session.token_digest, "there is no cookie on this channel"
    end

    # Meta sends wa_id without a leading +. Stored unnormalized it would never
    # match the number Task 4 sends *to*, and the same guest would get a second
    # session the moment anything else wrote the E.164 form.
    test "Meta's wa_id is normalized to E.164 before it becomes an identity" do
      route(payload_for(@stari_channel, text: "hello", wa_id: "38761555222"))

      assert with_tenant(@stari) { GuestSession.exists?(phone_e164: "+38761555222") }
    end

    # There is no checkbox on this channel and there cannot be one. Writing
    # a message to a number you chose to write to is the consent event.
    test "the guest's own first message is recorded as the consent event" do
      sent_at = Time.utc(2026, 8, 11, 12, 0, 0)

      route(payload_for(@stari_channel, text: "hello", timestamp: sent_at))

      session = with_tenant(@stari) { GuestSession.find_by!(channel: :whatsapp) }
      assert_equal sent_at, session.privacy_accepted_at
    end

    test "the WhatsApp profile name is the placeholder until the concierge asks for a real one" do
      route(payload_for(@stari_channel, text: "hello", profile_name: "Amira W"))

      assert_equal "Amira W", with_tenant(@stari) { GuestSession.find_by!(channel: :whatsapp).guest_name }
    end

    # A name is required by the schema, so something has to go there. The phone
    # number is language-neutral and tells a receptionist exactly who it is —
    # better than an invented English placeholder on a Bosnian workspace.
    test "with no profile name the phone number stands in, never an invented one" do
      route(payload_for(@stari_channel, text: "hello", wa_id: "38761555333", profile_name: nil))

      assert_equal "+38761555333", with_tenant(@stari) { GuestSession.find_by!(channel: :whatsapp).guest_name }
    end

    test "a returning guest reuses their own session rather than getting a second one" do
      route(payload_for(@stari_channel, text: "first", wa_id: "38761555444"))
      route(payload_for(@stari_channel, text: "second", wa_id: "38761555444", provider_message_id: "wamid.SECOND"))

      with_tenant(@stari) do
        assert_equal 1, GuestSession.where(channel: :whatsapp).count
        assert_equal 2, whatsapp_messages(@stari).count
      end
    end

    # The web's answer to an expired session is the entry form. There is no
    # form here, and the phone number's own unique index forbids a second row —
    # so the session is renewed and the room cleared, which is what makes the
    # concierge ask for it again on what is, in fact, a new stay.
    test "an expired session is renewed and its room cleared, not refused" do
      route(payload_for(@stari_channel, text: "first stay", wa_id: "38761555555"))
      session = with_tenant(@stari) do
        found = GuestSession.find_by!(phone_e164: "+38761555555")
        found.update_columns(room_id: rooms(:stari_301).id, expires_at: 2.days.ago)
        found
      end

      route(payload_for(@stari_channel, text: "back again", wa_id: "38761555555", provider_message_id: "wamid.RETURN"))

      with_tenant(@stari) do
        session.reload
        assert_nil session.room_id, "a new stay must be asked for its room again"
        assert session.expires_at.future?
        assert_equal 1, GuestSession.where(channel: :whatsapp).count
      end
    end

    test "a blocked guest session is ignored — the hotel already said no" do
      route(payload_for(@stari_channel, text: "first", wa_id: "38761555666"))
      with_tenant(@stari) { GuestSession.find_by!(phone_e164: "+38761555666").update!(status: :blocked) }

      route(payload_for(@stari_channel, text: "again", wa_id: "38761555666", provider_message_id: "wamid.BLOCKED"))

      assert_equal 1, whatsapp_messages(@stari).count
      assert @event.reload.ignored?
    end

    # --- The conversation and the message --------------------------------------

    test "the conversation is created on the whatsapp channel, not the web default" do
      route(payload_for(@stari_channel, text: "hello"))

      assert whatsapp_conversation(@stari).whatsapp?
    end

    test "the message carries Meta's own id as its dedupe anchor" do
      route(payload_for(@stari_channel, text: "hello", provider_message_id: "wamid.ANCHOR"))

      assert_equal "wamid.ANCHOR", whatsapp_messages(@stari).sole.external_id
    end

    # Meta retries a delivery it is not sure about, and the webhook controller
    # deliberately re-enqueues the job for the *same* webhook_events row on a
    # replay (so a crash between insert and enqueue is recoverable) — which
    # means this exact double-run is the normal case, not an edge one.
    # Exactly one message is the whole point.
    test "the same delivery processed twice produces exactly one message" do
      route(payload_for(@stari_channel, text: "only once", provider_message_id: "wamid.REPLAY"))

      reroute

      assert_equal 1, whatsapp_messages(@stari).count
      assert @event.reload.processed?
    end

    # The unique index on external_id is *global*, not per conversation — so a
    # replay arriving after the first conversation was resolved must still not
    # produce a second copy in the new one.
    test "a replay after the conversation was resolved still produces exactly one message" do
      route(payload_for(@stari_channel, text: "only once", provider_message_id: "wamid.REPLAY2"))
      with_tenant(@stari) { whatsapp_conversation(@stari).update!(status: :resolved) }

      reroute

      assert_equal 1, whatsapp_messages(@stari).count
    end

    # --- Downstream is unchanged ----------------------------------------------
    #
    # The brief's own test for the seam: run the same sentence through both
    # channels and assert the same rows come out. If this ever needs a
    # WhatsApp-shaped exception, the seam is in the wrong place.
    # (The enqueued reply job itself is asserted in
    # test/jobs/whatsapp/process_inbound_job_test.rb, where ActiveJob::TestCase
    # makes assert_enqueued_with available — this file is an
    # ActiveSupport::TestCase, per this suite's own convention.)

    test "a message arriving over WhatsApp produces the same rows a web message does" do
      web = with_tenant(@stari) do
        Conversation.live_for(guest_sessions(:stari_guest))
          .post_guest_message!(body: "šta ima za doručak?", client_message_id: SecureRandom.uuid)
      end

      route(payload_for(@stari_channel, text: "šta ima za doručak?"))
      whatsapp = whatsapp_messages(@stari).sole

      assert_equal web.body, whatsapp.body
      assert_equal web.sender_role, whatsapp.sender_role
      assert_equal web.visibility, whatsapp.visibility
      assert_equal web.hotel_id, whatsapp.hotel_id
      # The one row that is legitimately different, and the reason it is: the
      # dedupe anchor. The web has a browser-generated uuid; WhatsApp has
      # Meta's own message id.
      assert_nil web.external_id
      assert_equal "wamid.INBOUND1", whatsapp.external_id
    end

    test "the guest's message updates the 24-hour window anchor" do
      route(payload_for(@stari_channel, text: "hello"))

      assert_operator whatsapp_conversation(@stari).last_guest_message_at, :>, 1.minute.ago
    end

    # --- Delivery statuses -----------------------------------------------------
    #
    # Meta's receipts for messages *this app* sent. Slice 6 Task 4 is what
    # starts producing the external_ids they match on, so in production today
    # they will usually find nothing — which is correct, not a gap. The
    # never-move-backwards rule itself lives on Message and is proved there
    # (test/models/message_test.rb); what these pin is the routing half:
    # the right hotel's message, and never another hotel's.

    test "a status callback lands on the message it names" do
      message = outbound_message(@stari, "wamid.OUT1")

      route(status_payload(@stari_channel, "wamid.OUT1", "delivered"))

      assert with_tenant(@stari) { message.reload.delivery_status_delivered? }
      assert @event.reload.processed?
    end

    # The isolation boundary again, on the outbound half: hotel B's callback
    # must not be able to name hotel A's message. The lookup runs inside the
    # routed hotel's own tenant, which is what makes this structural rather
    # than a check someone remembered.
    test "a callback arriving on hotel B's number can never touch hotel A's message" do
      message = outbound_message(@stari, "wamid.OUT2")

      route(status_payload(@vrelo_channel, "wamid.OUT2", "read"))

      assert with_tenant(@stari) { message.reload.delivery_status_sent? }, "hotel A's message must be untouched"
      assert @event.reload.ignored?
    end

    test "a callback for a message this app has no record of is ignored, not an error" do
      route(status_payload(@stari_channel, "wamid.NEVER-SENT", "delivered"))

      assert @event.reload.ignored?
    end

    # --- Shapes this slice does not handle ------------------------------------

    test "a non-text message writes nothing and settles the event as ignored" do
      route(image_payload)

      assert_empty whatsapp_messages(@stari)
      assert @event.reload.ignored?
    end

    test "a payload carrying nothing actionable settles as ignored without touching a hotel" do
      route(template_status_payload)

      assert @event.reload.ignored?
      assert_empty whatsapp_messages(@stari)
    end

    # --- When something genuinely breaks ---------------------------------------
    #
    # The event row is the durable record of this delivery. A crash mid-way has
    # to leave it saying so, and must not re-raise: Meta was answered 200 long
    # ago, so a raise here only fills the failed-jobs table with something a
    # human has to read out of a stack trace instead of out of a row.

    test "an unexpected failure marks the event failed, reports it, and does not raise" do
      reported = capture_sentry_exceptions do
        with_broken(Conversation, :live_for) do
          route(payload_for(@stari_channel, text: "hello"))
        end
      end

      @event.reload
      assert @event.failed?
      assert_match "boom", @event.error
      assert_equal 1, reported.size
    end

    private
      def route(payload, external_id: nil)
        @event = WebhookEvent.create!(
          provider: :meta_cloud,
          external_id: external_id || "wamid.EVENT#{WebhookEvent.count}",
          payload: payload
        )
        InboundRouter.new(@event).route!
      end

      # A Meta retry, exactly as the webhook controller produces one: the same
      # stored row, routed a second time. Deliberately not "create a second
      # WebhookEvent with the same payload" — the composite unique index makes
      # that impossible, which is the point.
      def reroute = InboundRouter.new(@event).route!

      # Only the rows this slice created. The fixtures ship one web
      # conversation and one message per hotel, so a bare Message.count here
      # would be off by one in every assertion and — worse — would still pass
      # if the router wrote nothing at all.
      def whatsapp_messages(hotel)
        with_tenant(hotel) do
          Message.where(conversation_id: Conversation.where(channel: :whatsapp).select(:id)).to_a
        end
      end

      def whatsapp_conversation(hotel)
        with_tenant(hotel) { Conversation.where(channel: :whatsapp).sole }
      end

      def payload_for(channel, text:, wa_id: "38761234567", profile_name: "Amira W",
                      provider_message_id: "wamid.INBOUND1", timestamp: Time.utc(2026, 8, 11, 12, 0, 0),
                      phone_number_id: nil)
        contacts = profile_name ? [ { "profile" => { "name" => profile_name }, "wa_id" => wa_id } ] : []

        envelope(
          phone_number_id || channel.phone_number_id,
          "contacts" => contacts,
          "messages" => [ {
            "from" => wa_id, "id" => provider_message_id, "timestamp" => timestamp.to_i.to_s,
            "type" => "text", "text" => { "body" => text }
          } ]
        )
      end

      # A message this app sent and is waiting on a receipt for. Slice 6 Task 4
      # is what will really produce these; constructed directly here so the
      # routing half can be proved before the sending half exists.
      def outbound_message(hotel, external_id)
        with_tenant(hotel) do
          conversation = hotel == @stari ? conversations(:stari_conversation) : conversations(:vrelo_conversation)
          conversation.messages.create!(
            sender_role: :staff, sender_user: (hotel == @stari ? users(:stari_staff) : users(:vrelo_staff)),
            body: "On its way.", external_id: external_id, delivery_status: :sent
          )
        end
      end

      def status_payload(channel, provider_message_id, status)
        envelope(
          channel.phone_number_id,
          "statuses" => [ {
            "id" => provider_message_id, "status" => status,
            "timestamp" => "1786449600", "recipient_id" => "38761234567"
          } ]
        )
      end

      def image_payload
        envelope(
          @stari_channel.phone_number_id,
          "messages" => [ {
            "from" => "38761234567", "id" => "wamid.IMAGE1", "timestamp" => "1786449600",
            "type" => "image", "image" => { "id" => "MEDIA_ID", "mime_type" => "image/jpeg" }
          } ]
        )
      end

      def template_status_payload
        envelope(@stari_channel.phone_number_id, "event" => "APPROVED", "message_template_name" => "welcome")
      end

      def two_hotel_payload
        stari = payload_for(@stari_channel, text: "za Stari Grad")
        vrelo = payload_for(@vrelo_channel, text: "za Vrelo", wa_id: "38761999888",
                            provider_message_id: "wamid.INBOUND2")

        { "object" => "whatsapp_business_account", "entry" => stari["entry"] + vrelo["entry"] }
      end

      def envelope(phone_number_id, value)
        {
          "object" => "whatsapp_business_account",
          "entry" => [ {
            "id" => "WABA_ID",
            "changes" => [ {
              "field" => "messages",
              "value" => {
                "messaging_product" => "whatsapp",
                "metadata" => {
                  "display_phone_number" => "38761100100", "phone_number_id" => phone_number_id
                }
              }.merge(value)
            } ]
          } ]
        }
      end

      # Makes one collaborator blow up, to prove the router's own catch-all
      # actually catches. A singleton-method swap rather than Minitest::Mock's
      # `stub` (not loaded in this suite) — the same mechanism
      # #capture_sentry_exceptions below already uses.
      def with_broken(klass, method_name)
        original = klass.method(method_name)
        klass.define_singleton_method(method_name) { |*| raise ArgumentError, "boom" }
        yield
      ensure
        klass.define_singleton_method(method_name, original)
      end

      # Sentry.capture_exception is a real no-op with no SENTRY_DSN (test has
      # none), so the only way to assert it was called is to swap the method
      # out — the same shape test/jobs/ops/queue_health_job_test.rb uses.
      def capture_sentry_exceptions
        captured = []
        original = Sentry.method(:capture_exception)
        Sentry.define_singleton_method(:capture_exception) { |exception, **_options| captured << exception }
        yield
        captured
      ensure
        Sentry.define_singleton_method(:capture_exception, original)
      end
  end
end
