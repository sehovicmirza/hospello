require "test_helper"

module Retention
  # **Every test here asserts both halves.** A purge test that only checks
  # that old rows disappeared passes just as happily against a job that
  # deletes everything, and the fixture data — a live guest at each hotel,
  # mid-conversation — is what makes "and this is still here" mean something
  # rather than being a row picked because it was convenient.
  #
  # The setup builds, at *both* hotels, one of everything the policy names on
  # each side of every cutoff: a conversation nobody has written in since the
  # spring and one from this morning, a request past the chat window and one
  # past the operational window, a webhook that never routed to any hotel at
  # all. Two hotels because this is a job that crosses them by design, which
  # is the shape that has produced cross-tenant bugs in this codebase before.
  class PurgeExpiredGuestDataJobTest < ActiveJob::TestCase
    setup do
      @stari = hotels(:stari_grad)
      @vrelo = hotels(:vrelo)

      @old = build_old_data_for(@stari)
      @other_hotel_old = build_old_data_for(@vrelo)
    end

    # --- what goes -----------------------------------------------------------

    test "a conversation nobody has written in since before the window is deleted, and today's is not" do
      purge

      with_tenant(@stari) do
        assert_not Conversation.exists?(@old[:silent_conversation].id),
          "a conversation with no activity for #{Policy::GUEST_CHAT_DAYS} days should be gone"
        assert Conversation.exists?(conversations(:stari_conversation).id),
          "the live conversation this hotel is having right now must survive the purge"
      end
    end

    # A guest who opened the chat and never typed anything leaves a
    # conversation with last_message_at still null — and `NULL < cutoff` is
    # not true in SQL, so without the COALESCE these are the rows that are
    # never purged and nobody ever notices.
    test "a conversation the guest opened and never wrote in is purged on its creation date" do
      empty = with_tenant(@stari) do
        Conversation.create!(
          hotel: @stari, guest_session: @old[:regular_session], status: :resolved,
          created_at: 120.days.ago, updated_at: 120.days.ago
        )
      end
      assert_nil empty.last_message_at, "precondition: nothing was ever written in it"

      purge

      with_tenant(@stari) { assert_not Conversation.exists?(empty.id) }
    end

    test "the messages in a purged conversation go with it, and the live conversation's do not" do
      purge

      with_tenant(@stari) do
        assert_not Message.exists?(@old[:silent_message].id)
        assert Message.exists?(messages(:stari_first_message).id),
          "a message in a live conversation must survive"
      end
    end

    test "a guest session whose stay ended before the window is deleted, and a current guest is not" do
      purge

      with_tenant(@stari) do
        assert_not GuestSession.exists?(@old[:departed_session].id)
        assert GuestSession.exists?(guest_sessions(:stari_guest).id),
          "the guest currently in the hotel must still have an identity"
        assert_equal "Amira Fixture", guest_sessions(:stari_guest).reload.guest_name
      end
    end

    # The case a session-only sweep gets wrong. A WhatsApp identity is renewed
    # every time the guest writes, so a guest who comes back twice a year has
    # a session that never expires — and their first conversation would be
    # kept forever by a job that only looked at guest_sessions.
    test "a returning guest keeps their identity but not the conversation they had last spring" do
      purge

      with_tenant(@stari) do
        assert GuestSession.exists?(@old[:regular_session].id),
          "a guest whose session is still live has not left; their identity stays"
        assert_not Conversation.exists?(@old[:regulars_old_conversation].id),
          "their conversation from before the window is past its own retention regardless"
      end
    end

    test "a request past the chat window loses the guest and keeps the hotel's record of the work" do
      purge

      request = with_tenant(@stari) { ServiceRequest.find(@old[:anonymizable_request].id) }

      # What went, column by column — each one is named in the policy.
      assert_nil request.details_original, "the guest's own words"
      assert_nil request.original_locale
      assert_nil request.guest_session_id
      assert_nil request.conversation_id
      assert_nil request.room_id, "which room a person slept in is an identity"
      assert_empty request.details
      assert_not_includes request.summary, "Halilović",
        "the summary still names the guest"
      assert_not_includes request.summary, "302"

      # What stayed. Without these the test would pass against a job that
      # simply deleted the row, which is the failure this task cannot make.
      assert_equal "completed", request.status
      assert_equal request_categories(:stari_towels).id, request.request_category_id
      assert_equal request_categories(:stari_towels).name, request.summary,
        "the category is the hotel's own vocabulary and describes the work without describing the person"
      assert_equal users(:stari_staff).id, request.acknowledged_by_id
      assert_not_nil request.acknowledged_at
      assert_not_nil request.completed_at
      assert_not_nil request.anonymized_at
    end

    test "a request from this week is left exactly as the guest confirmed it" do
      purge

      request = with_tenant(@stari) { ServiceRequest.find(@old[:recent_request].id) }

      assert_equal "Two bath towels for Mr Halilović in 302", request.details_original
      assert_equal rooms(:stari_302).id, request.room_id
      assert_nil request.anonymized_at
      assert_not request.anonymized?
    end

    test "a request past the operational window is deleted outright, and one inside it is not" do
      purge

      with_tenant(@stari) do
        assert_not ServiceRequest.exists?(@old[:ancient_request].id)
        assert ServiceRequest.exists?(@old[:anonymizable_request].id),
          "a year-old request is the hotel's own history — anonymized, not deleted"
      end
    end

    test "a knowledge gap keeps its question and its count, and loses the guest's own sentence" do
      purge

      with_tenant(@stari) do
        old_gap = UnansweredQuestion.find(@old[:old_gap].id)
        assert_nil old_gap.question_original
        assert_equal "is there parking", old_gap.question,
          "the generalized question is the hotel's backlog, not a guest's data"
        assert_equal 14, old_gap.asked_count,
          "deleting the row would reset the count that is the whole point of the screen"

        assert_equal "my mother uses a wheelchair, is there a ramp",
          UnansweredQuestion.find(@old[:recent_gap].id).question_original
      end
    end

    test "AI telemetry older than the operational window goes, and this month's stays" do
      purge

      with_tenant(@stari) do
        assert_not AiRun.exists?(@old[:ancient_run].id)
        assert AiRun.exists?(@old[:recent_run].id)
        assert AiRun.exists?(@old[:middle_aged_run].id),
          "telemetry carries no guest content and is kept for the operational window, " \
          "not the chat one — this row is the difference between the two"
      end
    end

    # webhook_events is the one table with no tenant scope, and rows that
    # never routed have no hotel at all — a per-hotel loop would never reach
    # a single one of them, and they carry a real phone number and a real
    # message.
    test "raw provider callbacks are purged past their own window, including ones that never routed" do
      purge

      assert_not WebhookEvent.exists?(@old[:old_routed_event].id)
      assert_not WebhookEvent.exists?(@old[:old_unrouted_event].id),
        "a delivery that never found a hotel still carries the guest's number"
      assert WebhookEvent.exists?(@old[:recent_event].id)
    end

    # --- the other hotel ------------------------------------------------------

    test "the other hotel's old data is purged too — this job is not one hotel's" do
      purge

      with_tenant(@vrelo) do
        assert_not Conversation.exists?(@other_hotel_old[:silent_conversation].id)
        assert_not GuestSession.exists?(@other_hotel_old[:departed_session].id)
      end
    end

    test "the other hotel's live conversation is untouched" do
      purge

      with_tenant(@vrelo) do
        assert Conversation.exists?(conversations(:vrelo_conversation).id)
        assert Message.exists?(messages(:vrelo_first_message).id)
        assert GuestSession.exists?(guest_sessions(:vrelo_guest).id)
      end
    end

    # --- how it runs ----------------------------------------------------------

    test "it runs with no ambient tenant and leaves none behind" do
      assert_nil ActsAsTenant.current_tenant, "precondition: the scheduler sets no tenant"

      purge

      assert_nil ActsAsTenant.current_tenant
    end

    test "running it again changes nothing" do
      purge
      counts = row_counts
      purge

      assert_equal counts, row_counts
    end

    # The bug this catches is a batching loop that only ever processes its
    # first batch: everything up to one batch disappears, the rest is kept
    # forever, and no test with three fixture rows in it would ever notice.
    # Five old conversations against a batch size of two.
    #
    # Hung off the guest who is still here — the first version of this test
    # used the departed guest's session, whose own deletion cascades to every
    # conversation it owns, so it passed with the batching loop deliberately
    # broken. Measured, not reasoned about: the break came back green.
    test "it keeps going past the first batch" do
      extra = with_tenant(@stari) do
        (10..13).map { |index| silent_conversation_for(@stari, @old[:regular_session], index) }
      end

      with_batch_size(2) { purge }

      with_tenant(@stari) do
        assert_empty Conversation.where(id: extra.map(&:id)),
          "conversations past the first batch were left behind"
      end
    end

    # The same question for the one statement in this job that is not an
    # ordinary Rails write: anonymization is a raw UPDATE with a correlated
    # subquery, run through the same in_batches loop, and "does that compose"
    # is worth an assertion rather than a reading of the Rails source.
    test "it anonymizes past the first batch too" do
      category = request_categories(:stari_towels)
      extra = with_tenant(@stari) do
        3.times.map { request_for(@stari, category, rooms(:stari_302), users(:stari_staff), age: 120.days) }
      end

      with_batch_size(2) { purge }

      with_tenant(@stari) do
        still_identifiable = ServiceRequest.where(id: extra.map(&:id)).where(anonymized_at: nil)
        assert_empty still_identifiable, "requests past the first batch kept the guest's words"
      end
    end

    # --- the numbers are the policy's, not this job's -------------------------

    # Hung off the guest who is still here, deliberately: the departed guest's
    # session is itself past its window, so its conversations go with it by
    # cascade whatever their own timestamps say — and this test would then
    # pass without the conversation clock working at all.
    test "a conversation an hour inside the window survives and one an hour past it does not" do
      inside, outside = with_tenant(@stari) do
        [
          silent_conversation_for(@stari, @old[:regular_session], 91,
            last_message_at: Policy::GUEST_CHAT_DAYS.days.ago + 1.hour),
          silent_conversation_for(@stari, @old[:regular_session], 92,
            last_message_at: Policy::GUEST_CHAT_DAYS.days.ago - 1.hour)
        ]
      end

      purge

      with_tenant(@stari) do
        assert Conversation.exists?(inside.id), "one hour inside the window is inside it"
        assert_not Conversation.exists?(outside.id)
      end
    end

    private
      def purge = PurgeExpiredGuestDataJob.perform_now

      def with_batch_size(size)
        original = PurgeExpiredGuestDataJob::BATCH_SIZE
        PurgeExpiredGuestDataJob.send(:remove_const, :BATCH_SIZE)
        PurgeExpiredGuestDataJob.const_set(:BATCH_SIZE, size)
        yield
      ensure
        PurgeExpiredGuestDataJob.send(:remove_const, :BATCH_SIZE)
        PurgeExpiredGuestDataJob.const_set(:BATCH_SIZE, original)
      end

      def row_counts
        with_tenant(@stari) do
          {
            conversations: Conversation.count, messages: Message.count,
            guest_sessions: GuestSession.count, service_requests: ServiceRequest.count,
            unanswered_questions: UnansweredQuestion.count, ai_runs: AiRun.count,
            webhook_events: WebhookEvent.count
          }
        end
      end

      # One of everything the policy names, on both sides of every cutoff.
      # Named fixtures rather than `hotel.rooms.first`, so an assertion about
      # which room or category survived is about the row this really used.
      def build_old_data_for(hotel)
        stari = hotel == @stari
        room = rooms(stari ? :stari_302 : :vrelo_401)
        category = request_categories(stari ? :stari_towels : :vrelo_wakeup)
        staff = users(stari ? :stari_staff : :vrelo_staff)

        with_tenant(hotel) do
          departed = guest_session_for(hotel, room, name: "Emina Departed", expires_at: 100.days.ago)
          regular = guest_session_for(hotel, room, name: "Regular Returner", expires_at: 5.days.from_now)

          {
            departed_session: departed,
            regular_session: regular,
            silent_conversation: silent_conversation_for(hotel, departed, 0),
            silent_message: nil, # filled in below
            regulars_old_conversation: silent_conversation_for(hotel, regular, 1),
            anonymizable_request: request_for(hotel, category, room, staff, age: 100.days),
            ancient_request: request_for(hotel, category, room, staff, age: 400.days),
            recent_request: request_for(hotel, category, room, staff, age: 2.days),
            old_gap: gap_for(hotel, "is there parking", "is there parking near the hotel for a van",
              age: 100.days, asked_count: 14),
            recent_gap: gap_for(hotel, "is there a ramp",
              "my mother uses a wheelchair, is there a ramp", age: 3.days),
            ancient_run: run_for(hotel, age: 400.days),
            middle_aged_run: run_for(hotel, age: 200.days),
            recent_run: run_for(hotel, age: 2.days),
            old_routed_event: webhook_event_for(hotel, age: 40.days),
            old_unrouted_event: webhook_event_for(nil, age: 40.days),
            recent_event: webhook_event_for(hotel, age: 2.days)
          }.tap do |data|
            data[:silent_message] = data[:silent_conversation].messages.create!(
              hotel: hotel, sender_role: :guest, body: "Could I have a late checkout?",
              created_at: 100.days.ago, updated_at: 100.days.ago
            )
          end
        end
      end

      def guest_session_for(hotel, room, name:, expires_at:)
        GuestSession.create!(
          hotel: hotel, room: room, guest_name: name, locale: "bs",
          privacy_accepted_at: 200.days.ago, expires_at: expires_at,
          created_at: 200.days.ago, updated_at: 200.days.ago
        )
      end

      # `resolved`, because the partial unique index allows exactly one live
      # conversation per guest session and each of these sessions has one.
      def silent_conversation_for(hotel, session, seed, last_message_at: (100 + seed).days.ago)
        Conversation.create!(
          hotel: hotel, guest_session: session, status: :resolved,
          last_message_at: last_message_at, last_guest_message_at: last_message_at,
          created_at: last_message_at, updated_at: last_message_at
        )
      end

      def request_for(hotel, category, room, staff, age:)
        ServiceRequest.create!(
          hotel: hotel, request_category: category, room: room,
          guest_session: guest_sessions(hotel == @stari ? :stari_guest : :vrelo_guest),
          conversation: conversations(hotel == @stari ? :stari_conversation : :vrelo_conversation),
          summary: "Two bath towels for Mr Halilović in 302",
          details_original: "Two bath towels for Mr Halilović in 302",
          details: { "quantity" => "2", "description" => "bath towels" },
          original_locale: "de", status: :completed,
          acknowledged_by: staff, acknowledged_at: age.ago + 10.minutes,
          completed_at: age.ago + 30.minutes,
          dedupe_key: SecureRandom.hex(16), created_at: age.ago, updated_at: age.ago
        )
      end

      def gap_for(hotel, question, original, age:, asked_count: 1)
        UnansweredQuestion.create!(
          hotel: hotel, question: question, question_original: original,
          locale: "en", asked_count: asked_count, created_at: age.ago, updated_at: age.ago
        )
      end

      def run_for(hotel, age:)
        AiRun.create!(
          hotel: hotel, kind: :reply, status: :success, model: "test-model",
          input_tokens: 10, output_tokens: 5, created_at: age.ago, updated_at: age.ago
        )
      end

      def webhook_event_for(hotel, age:)
        WebhookEvent.create!(
          provider: :meta_cloud, external_id: SecureRandom.uuid, hotel: hotel,
          payload: { "from" => "38761234567", "text" => "Is breakfast still on?" },
          created_at: age.ago, updated_at: age.ago
        )
      end
  end
end
