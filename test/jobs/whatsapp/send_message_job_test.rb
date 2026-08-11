require "test_helper"

module Whatsapp
  # The first thing in this app that puts text somewhere it cannot be taken
  # back, which is what every test below is really about. On the web a mistake
  # is fixed by fixing the row and letting both surfaces re-render; here the
  # guest already has the message on their own device.
  #
  # The provider is a real Whatsapp::Provider (FakeWhatsappProvider subclasses
  # the port), never a mock of the job's own behaviour. What goes out on the
  # wire is asserted against WebMock in
  # test/services/whatsapp/meta_cloud_provider_test.rb; what this file asserts
  # is what the *job* decides to hand it, and what it does with each answer.
  class SendMessageJobTest < ActiveJob::TestCase
    setup do
      @hotel = hotels(:stari_grad)
      @channel = with_tenant(@hotel) { whatsapp_channels(:stari_grad_whatsapp) }
      @provider = FakeWhatsappProvider.new
      ActsAsTenant.current_tenant = @hotel
      @conversation = whatsapp_conversation
    end

    # --- What goes out --------------------------------------------------------

    test "a staff reply goes to the guest's own number, on their hotel's channel" do
      message = staff_reply("Peškiri stižu za pet minuta.")

      send_now(message)

      sent = @provider.last_send
      assert_equal "+38761234567", sent[:to]
      assert_equal @channel, sent[:channel]
      assert_equal "Peškiri stižu za pet minuta.", sent[:body]
      # The provider enforces Meta's 24-hour window itself and needs the
      # conversation to do it — passing nil would make every send outside the
      # window succeed silently.
      assert_equal @conversation, sent[:conversation]
    end

    test "the provider's own message id becomes the delivery anchor" do
      message = staff_reply("On its way.")

      send_now(message)

      message.reload
      assert_equal "wamid.FAKE1", message.external_id
      assert message.delivery_status_sent?
    end

    # Whatsapp::InboundRouter matches every delivery receipt on external_id, so
    # a send that forgot to record one is a message no callback can ever reach.
    test "a receipt for what was just sent finds the message it belongs to" do
      message = staff_reply("On its way.")
      send_now(message)

      applied = message.reload.apply_delivery_status!(
        Whatsapp::DeliveryStatus.new(provider_message_id: message.external_id, status: "delivered",
                                     timestamp: Time.current)
      )

      assert applied
      assert message.reload.delivery_status_delivered?
    end

    # --- What must never go out ------------------------------------------------

    # The one that cannot be undone. Internal notes share the messages table
    # with replies, and on the web a mistake here shows a note in a browser
    # that can be corrected; here it is on the guest's phone forever.
    test "an internal note is never sent, however it was written" do
      note = with_tenant(@hotel) do
        @conversation.post_internal_note!(user: users(:stari_staff), body: "Guest complained last night.")
      end

      send_now(note)

      assert_empty @provider.sends
      assert note.reload.delivery_status_local?, "nothing was even claimed for delivery"
    end

    test "the guest's own message is never sent back to them" do
      guest_message = with_tenant(@hotel) do
        @conversation.post_guest_message!(body: "Treba mi peškir", external_id: "wamid.FROMGUEST")
      end

      send_now(guest_message)

      assert_empty @provider.sends
    end

    # The web guest is given a phone number on purpose. Without one this test
    # passes on the "no recipient" guard instead of the channel guard —
    # measured: deleting `return false unless conversation.whatsapp?` left it
    # green, because no fixture guest session carries a phone_e164. A web guest
    # really can have one (the entry form's phone field is optional but real),
    # and giving them one here is what makes the channel the only thing
    # standing between this reply and WhatsApp.
    test "nothing is sent for a conversation that is not on WhatsApp" do
      web_message = with_tenant(@hotel) do
        guest_sessions(:stari_guest).update!(phone_e164: "+38761999000")
        conversations(:stari_conversation).post_staff_message!(user: users(:stari_staff), body: "Hello")
      end

      send_now(web_message)

      assert_empty @provider.sends
    end

    test "a channel the hotel has switched off sends nothing" do
      with_tenant(@hotel) { @channel.update!(status: :disabled) }
      message = staff_reply("Hello")

      send_now(message)

      assert_empty @provider.sends
    end

    # A send that goes out twice cannot be recalled and the guest simply sees
    # the hotel say the same thing twice. The claim is a single atomic
    # statement for exactly this reason.
    test "the same message enqueued twice is sent exactly once" do
      message = staff_reply("Only once, please.")

      2.times { send_now(message) }

      assert_equal 1, @provider.sends.size
    end

    # --- Waiting for the translation -------------------------------------------
    #
    # The decision this job exists to get right. On the web the translation
    # lands as an overlay into a page already showing the message; there is no
    # overlay on WhatsApp, so sending first and translating after means the
    # guest receives two messages, one of which they cannot read.

    test "a reply still being translated is not sent yet" do
      message = staff_reply_awaiting_translation

      send_now(message)

      assert_empty @provider.sends, "the guest would have received words they cannot read"
      assert message.reload.delivery_status_local?, "and nothing was claimed, so the retry can still send it"
    end

    test "once the translation lands, that is what the guest receives" do
      message = staff_reply_awaiting_translation
      send_now(message) # too early — waits

      with_tenant(@hotel) do
        message.update!(translated_body: "Die Handtücher kommen gleich.", translated_locale: "de",
                        translation_status: :translated)
      end
      send_now(message)

      assert_equal "Die Handtücher kommen gleich.", @provider.last_send[:body]
    end

    # The wait has to end. Ai::TranslationWatchdogJob settles anything stuck
    # after its own budget, and this job's attempt cap is derived from that
    # constant — but the guest must get *something* either way, and the
    # original is always better than silence.
    test "when the wait runs out the guest gets the original rather than nothing" do
      message = staff_reply_awaiting_translation

      send_now(message, attempt: SendMessageJob::MAX_ATTEMPTS)

      assert_equal "Peškiri stižu za pet minuta.", @provider.last_send[:body]
    end

    test "the wait is bounded by the watchdog's own budget, not by a number typed here" do
      assert_operator SendMessageJob::MAX_ATTEMPTS * SendMessageJob::POLL_INTERVAL, :>,
                      Ai::TranslationWatchdogJob::BUDGET,
                      "the wait must outlast the thing that settles what it is waiting for"
    end

    # --- When the send does not work --------------------------------------------

    # Not an error on anyone's part — Meta's rule is that a hotel may only
    # write freely within 24 hours of the guest's last message. What matters is
    # that the receptionist finds out, because from their side the reply looks
    # sent.
    test "a closed 24-hour window marks the message failed rather than losing it quietly" do
      @provider.script_failure(WindowClosedError.new("window closed"))
      message = staff_reply("Are you still there?")

      send_now(message)

      assert message.reload.delivery_status_failed?
      assert_equal "Are you still there?", message.body, "the words are kept; only the delivery failed"
    end

    test "a hard API failure is reported and marked failed" do
      @provider.script_failure(ApiError.new("nope", status: 500))
      message = staff_reply("Hello")

      reported = capture_sentry_exceptions { send_now(message) }

      assert message.reload.delivery_status_failed?
      assert_equal 1, reported.size
    end

    # Meta asking us to slow down is not a refusal. Re-raised so the queue
    # retries rather than dropping a reply a guest is waiting for.
    test "a rate limit is retried rather than marked failed" do
      @provider.script_failure(RateLimitedError.new("slow down", retry_after: 30))
      message = staff_reply("Hello")

      capture_sentry_exceptions do
        assert_raises(RateLimitedError) { send_now(message) }
      end

      assert_not message.reload.delivery_status_failed?, "a retryable failure must not look settled"
    end

    # --- The wiring ------------------------------------------------------------
    #
    # Conversation posts six kinds of message. On the web the ones that are not
    # staff replies still reach the guest, because their browser re-renders
    # from the database; on WhatsApp nothing reaches them unless something
    # sends it.

    test "every guest-visible message on a WhatsApp conversation is enqueued for sending" do
      with_tenant(@hotel) do
        assert_enqueued_with(job: SendMessageJob) do
          @conversation.post_staff_message!(user: users(:stari_staff), body: "A staff reply")
        end
        assert_enqueued_with(job: SendMessageJob) do
          @conversation.post_assistant_reply!(body: "An assistant reply")
        end
        assert_enqueued_with(job: SendMessageJob) do
          @conversation.post_system_notice!(body: "A receipt")
        end
      end
    end

    test "an internal note is not even enqueued" do
      with_tenant(@hotel) do
        assert_no_enqueued_jobs(only: SendMessageJob) do
          @conversation.post_internal_note!(user: users(:stari_staff), body: "Private")
        end
      end
    end

    test "a web conversation enqueues nothing at all" do
      with_tenant(@hotel) do
        assert_no_enqueued_jobs(only: SendMessageJob) do
          conversations(:stari_conversation).post_staff_message!(user: users(:stari_staff), body: "Hello")
        end
      end
    end

    private
      def whatsapp_conversation
        session = GuestSession.for_whatsapp(
          phone_e164: "+38761234567", name: "Amira", accepted_at: Time.current
        )
        session.update!(room: rooms(:stari_301), locale: "bs")
        Conversation.live_for(session)
      end

      def staff_reply(body)
        with_tenant(@hotel) { @conversation.post_staff_message!(user: users(:stari_staff), body: body) }
      end

      # A reply whose guest reads a different language, so a translation really
      # is on its way. Both locales are set explicitly: the fixtures give both
      # hotels `bs` for staff and guest, so a test that set only one would pass
      # whichever way round the code had it.
      def staff_reply_awaiting_translation
        with_tenant(@hotel) do
          @conversation.guest_session.update!(locale: "de")
          @conversation.update!(guest_locale: "de")
          @conversation.post_staff_message!(user: users(:stari_staff), body: "Peškiri stižu za pet minuta.")
        end
      end

      def send_now(message, attempt: 1)
        with_tenant(@hotel) { SendMessageJob.perform_now(message, provider: @provider, attempt: attempt) }
      end

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
