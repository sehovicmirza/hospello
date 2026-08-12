require "test_helper"

module Retention
  # Erasure has the same trap the purge does and one of its own: a test that
  # asserts "the guest is gone" passes against a service that empties the
  # database. Every test here names something that must still be standing
  # afterwards — the guest in the next room, the other hotel, and the hotel's
  # own record of work its staff actually did.
  #
  # The one of its own: an erasure that cannot be proved is not much of an
  # erasure, and a proof that copies the erased data into a table this policy
  # keeps forever is worse than none.
  class GuestErasureTest < ActiveSupport::TestCase
    setup do
      @hotel = hotels(:stari_grad)
      @vrelo = hotels(:vrelo)
      @platform_admin = users(:platform)

      @session = guest_sessions(:stari_guest)
      @conversation = with_tenant(@hotel) { conversations(:stari_conversation) }
      @message = with_tenant(@hotel) { messages(:stari_first_message) }
      @request = with_tenant(@hotel) { create_request_for(@session, @conversation) }
      @gap = with_tenant(@hotel) { create_gap_for(@conversation) }

      # The guest in the next room, at the same hotel, who did not ask for
      # anything to be erased.
      @neighbour = with_tenant(@hotel) { create_neighbour }
    end

    test "the guest's identity and everything they wrote is gone" do
      erase

      with_tenant(@hotel) do
        assert_not GuestSession.exists?(@session.id)
        assert_not Conversation.exists?(@conversation.id)
        assert_not Message.exists?(@message.id)
      end
    end

    test "the guest in the next room is untouched" do
      erase

      with_tenant(@hotel) do
        assert GuestSession.exists?(@neighbour[:session].id)
        assert Conversation.exists?(@neighbour[:conversation].id)
        assert Message.exists?(@neighbour[:message].id)
        assert_equal "Neighbour Fixture", @neighbour[:session].reload.guest_name
      end
    end

    # The neighbour's *request* specifically: anonymizing "this hotel's
    # requests" instead of "this guest's requests" is a one-word difference
    # that no test about deletion would ever notice, and it would quietly
    # strip the board of every guest's details the first time anyone was
    # erased.
    test "the guest in the next room keeps their own request, guest details and all" do
      erase

      request = with_tenant(@hotel) { ServiceRequest.find(@neighbour[:request].id) }

      assert_equal "Extra towels for the Neighbour in 302", request.details_original
      assert_equal @neighbour[:session].id, request.guest_session_id
      assert_not request.anonymized?
    end

    test "the other hotel's guests are untouched" do
      erase

      with_tenant(@vrelo) do
        assert GuestSession.exists?(guest_sessions(:vrelo_guest).id)
        assert Conversation.exists?(conversations(:vrelo_conversation).id)
        assert Message.exists?(messages(:vrelo_first_message).id)
      end
    end

    test "the hotel keeps its record of the work and loses the guest from it" do
      erase

      request = with_tenant(@hotel) { ServiceRequest.find(@request.id) }

      assert_nil request.details_original
      assert_nil request.guest_session_id
      assert_nil request.conversation_id
      assert_nil request.room_id
      assert_not_includes request.summary, "Amira"

      assert_equal "completed", request.status
      assert_equal request_categories(:stari_towels).name, request.summary
      assert_not_nil request.completed_at
      assert request.anonymized?
    end

    test "the knowledge gap keeps its question and loses the guest's own sentence" do
      erase

      with_tenant(@hotel) do
        gap = UnansweredQuestion.find(@gap.id)
        assert_nil gap.question_original
        assert_equal "is there a late checkout", gap.question
      end
    end

    # --- the record that has to survive ---------------------------------------

    test "the erasure is recorded against the hotel, with counts of what went" do
      erase

      entry = AuditLog.for_hotel(@hotel).where(action: "guest_data.erase").last
      assert entry, "an erasure that leaves no trace cannot be proved to have happened"
      assert_equal @platform_admin.id, entry.actor_user_id
      assert_equal @session.id, entry.metadata["guest_session_id"]
      assert_equal 1, entry.metadata["conversations"]
      assert_equal 1, entry.metadata["messages"]
      assert_equal 1, entry.metadata["service_requests_anonymized"]
    end

    # The proof must not be a copy of what it destroyed. Written as a scan of
    # the whole row rather than a check of the fields we happen to set today,
    # so a future field carrying a name fails this too.
    test "the record of the erasure names nobody" do
      whatsapp_session = with_tenant(@hotel) { create_whatsapp_guest }
      GuestErasure.call(guest_session: whatsapp_session, actor: @platform_admin)

      entry = AuditLog.for_hotel(@hotel).where(action: "guest_data.erase").last.attributes.to_s

      assert_not_includes entry, "Hasan Traveller"
      assert_not_includes entry, "+38761900900"
      assert_not_includes entry, "61900900"
    end

    # --- WhatsApp's raw payloads ----------------------------------------------

    test "a WhatsApp guest's raw provider callbacks go too" do
      whatsapp_session = with_tenant(@hotel) { create_whatsapp_guest }
      theirs = webhook_event(@hotel, "38761900900")
      same_number_another_hotel = webhook_event(@vrelo, "38761900900")
      somebody_else = webhook_event(@hotel, "38765111222")

      GuestErasure.call(guest_session: whatsapp_session, actor: @platform_admin)

      assert_not WebhookEvent.exists?(theirs.id)
      assert WebhookEvent.exists?(somebody_else.id),
        "another guest's delivery, at the same hotel"
      assert WebhookEvent.exists?(same_number_another_hotel.id),
        "another hotel's record of the same person writing to them is not this hotel's to destroy"
    end

    test "a web guest with no phone number leaves the webhook table alone" do
      before = WebhookEvent.count
      webhook_event(@hotel, "38765111222")

      erase

      assert_equal before + 1, WebhookEvent.count
    end

    # --- the confirmation, and the transaction --------------------------------

    # The screen tells a platform admin exactly what is about to be destroyed,
    # and it is irreversible — so the number it shows has to be the number
    # that goes, not a second query's opinion of it.
    test "the confirmation counts exactly what the erasure then destroys" do
      preview = GuestErasure.preview(guest_session: @session)

      before = with_tenant(@hotel) do
        { conversations: Conversation.count, messages: Message.count }
      end
      erase
      after = with_tenant(@hotel) do
        { conversations: Conversation.count, messages: Message.count }
      end

      assert_equal preview.conversations, before[:conversations] - after[:conversations]
      assert_equal preview.messages, before[:messages] - after[:messages]
      assert_equal 1, preview.service_requests
      assert_equal 1, preview.knowledge_gaps
    end

    # Half an erasure is the worst outcome available: the guest believes they
    # are gone, the hotel believes its records are intact, and neither is
    # true. AuditLog.record! is the last step, so making it fail is the way to
    # test that everything before it rolls back. A plain singleton swap
    # restored in `ensure`, for the reason
    # test/controllers/platform/hotels_controller_test.rb documents:
    # minitest/mock's Object#stub needs a gem this Gemfile does not carry.
    test "an erasure that cannot be recorded does not happen at all" do
      original = AuditLog.method(:record!)

      begin
        AuditLog.define_singleton_method(:record!) { |**| raise "simulated audit failure" }
        assert_raises(RuntimeError) { erase }
      ensure
        AuditLog.define_singleton_method(:record!, original)
      end

      with_tenant(@hotel) do
        assert GuestSession.exists?(@session.id), "the guest was erased with no record of it"
        assert Message.exists?(@message.id)
        assert_not ServiceRequest.find(@request.id).anonymized?
      end
    end

    private
      def erase = GuestErasure.call(guest_session: @session, actor: @platform_admin)

      def create_request_for(session, conversation)
        category = request_categories(:stari_towels)
        ServiceRequest.create!(
          hotel: @hotel, request_category: category, department: category.department,
          room: rooms(:stari_301), guest_session: session, conversation: conversation,
          summary: "Extra towels for Amira in 301", details_original: "Extra towels for Amira in 301",
          details: { "quantity" => "2" }, original_locale: "bs", status: :completed,
          completed_at: 1.hour.ago,
          dedupe_key: SecureRandom.hex(16)
        )
      end

      def create_gap_for(conversation)
        UnansweredQuestion.create!(
          hotel: @hotel, conversation: conversation, question: "is there a late checkout",
          question_original: "Amira here — can I keep the room until 4?", locale: "en"
        )
      end

      def create_neighbour
        session = GuestSession.create!(
          hotel: @hotel, room: rooms(:stari_302), guest_name: "Neighbour Fixture", locale: "en",
          privacy_accepted_at: 1.day.ago, expires_at: 6.days.from_now
        )
        conversation = Conversation.create!(hotel: @hotel, guest_session: session, status: :active)
        message = conversation.messages.create!(hotel: @hotel, sender_role: :guest, body: "Any parking?")
        category = request_categories(:stari_towels)
        request = ServiceRequest.create!(
          hotel: @hotel, request_category: category, department: category.department,
          room: rooms(:stari_302), guest_session: session, conversation: conversation,
          summary: "Extra towels for the Neighbour in 302",
          details_original: "Extra towels for the Neighbour in 302",
          details: { "quantity" => "1" }, original_locale: "en",
          dedupe_key: SecureRandom.hex(16)
        )

        { session: session, conversation: conversation, message: message, request: request }
      end

      def create_whatsapp_guest
        GuestSession.create!(
          hotel: @hotel, channel: :whatsapp, phone_e164: "+38761900900",
          guest_name: "Hasan Traveller", locale: "bs",
          privacy_accepted_at: 1.day.ago, expires_at: 6.days.from_now
        )
      end

      def webhook_event(hotel, from)
        WebhookEvent.create!(
          provider: :meta_cloud, external_id: SecureRandom.uuid, hotel: hotel,
          payload: { "messages" => [ { "from" => from, "text" => { "body" => "Hello" } } ] }
        )
      end
  end
end
