require "test_helper"

module Ai
  # The job that decides whether a guest hears from the assistant at all.
  #
  # The single most important test in this file is the last one: with the
  # model raising on every single call, the guest's message still reaches the
  # reception inbox. That is acceptance scenario 12, and it is the promise
  # that makes shipping an AI concierge defensible at all.
  class GenerateReplyJobTest < ActiveJob::TestCase
    setup do
      @hotel = hotels(:stari_grad)
      ActsAsTenant.current_tenant = @hotel
      @conversation = conversations(:stari_conversation)
      @guest_message = @conversation.messages.order(:id).last
      @fake = FakeClaude.new
      @store = ActiveSupport::Cache::MemoryStore.new
      @breaker = Ai::CircuitBreaker.new(@hotel, store: @store)
    end

    test "posts the assistant's answer to the guest and records the run" do
      @fake.script_text("Doručak je od 07:00 do 10:30.", input_tokens: 4_000, output_tokens: 20,
                        cache_read_input_tokens: 3_800)

      perform

      reply = @conversation.messages.order(:id).last
      assert_equal "assistant", reply.sender_role
      assert_equal "Doručak je od 07:00 do 10:30.", reply.body
      assert reply.guest_visible?
      assert_equal "bs", reply.body_locale

      run = AiRun.order(:id).last
      assert_equal "success", run.status
      assert_equal "reply", run.kind
      assert_equal @guest_message.id, run.message_id
      assert_equal 4_000, run.input_tokens
      assert_equal 3_800, run.cache_read_tokens
      assert_equal Rails.configuration.x.ai.model, run.model
      assert run.latency_ms.present?
    end

    test "an answered conversation is no longer waiting on a receptionist" do
      @conversation.update!(staff_unread_count: 3)
      @fake.script_text("Da, imamo.")

      perform

      assert_equal 0, @conversation.reload.staff_unread_count
      assert_not @conversation.needs_attention?
    end

    # --- Coalescing -------------------------------------------------------------

    test "a second job for the same guest message does nothing" do
      @fake.script_text("First answer.")

      perform
      perform # would raise FakeClaude::UnscriptedCall if it called the model again

      assert_equal 1, AiRun.count
      assert_equal 1, @conversation.messages.where(sender_role: :assistant).count
    end

    # Three messages in five seconds is one guest on a slow phone, not three
    # questions. They get one reply that saw all three, rather than three
    # replies that each saw a different prefix.
    test "messages that arrived while the job waited are answered together, once" do
      second = @conversation.messages.create!(hotel: @hotel, sender_role: :guest, body: "And are there towels?")
      @fake.script_text("Both answered.")

      perform
      perform

      assert_equal 1, @conversation.messages.where(sender_role: :assistant).count
      assert_equal second.id, AiRun.order(:id).last.message_id
      assert_includes @fake.prompt_text, "And are there towels?"
    end

    test "a new guest message after a reply is answered on its own" do
      @fake.script_text("First.").script_text("Second.")

      perform
      @conversation.messages.create!(hotel: @hotel, sender_role: :guest, body: "One more thing?")
      perform

      assert_equal 2, @conversation.messages.where(sender_role: :assistant).count
      assert_equal 2, AiRun.count
    end

    # --- Guards 1 and 2: the assistant is switched off ----------------------------

    test "a paused conversation gets no reply and no notice" do
      @conversation.update!(ai_mode: :paused)

      assert_no_difference -> { @conversation.messages.count } do
        perform
      end
      assert_equal 0, AiRun.count, "no model ran, so there is no run to account for"
    end

    test "a hotel with the assistant switched off gets no reply and no notice" do
      @hotel.update!(ai_enabled: false)

      assert_no_difference -> { @conversation.messages.count } do
        perform
      end
      assert_equal 0, AiRun.count
    end

    # A receptionist can press Pause AI while the model is mid-sentence. Every
    # guard before the call has already passed by then, so the only place that
    # race can be settled is the moment of the write — which is why
    # Conversation#post_assistant_reply! re-checks ai_mode inside its own
    # transaction rather than trusting the check this job did earlier.
    #
    # The pause happens *during* the model call, from inside the client, which
    # is the only way to land it in the window that actually matters.
    test "a takeover mid-flight discards the reply instead of posting under it" do
      pausing_client = Class.new(FakeClaude) do
        attr_accessor :conversation_to_pause

        def chat(**kwargs)
          conversation_to_pause.update_column(:ai_mode, Conversation.ai_modes[:paused])
          super
        end
      end.new
      pausing_client.conversation_to_pause = Conversation.find(@conversation.id)
      pausing_client.script_text("Too late — reception has this now.")

      Ai::GenerateReplyJob.perform_now(@conversation, client: pausing_client, breaker: @breaker)

      assert_equal 0, @conversation.reload.messages.where(sender_role: :assistant).count
      assert_equal 1, pausing_client.call_count, "precondition: the model was called before the pause landed"
      assert_equal "success", AiRun.order(:id).last.status,
                   "the tokens were spent whether or not the answer was used"
    end

    # --- Guards 3 and 4: the assistant is on but cannot run -------------------------

    test "an open circuit breaker degrades without calling the model" do
      @breaker.open!

      perform # no scripted response: calling the model would raise

      assert_degraded(status: "circuit_open", reason: "ai_unavailable")
    end

    test "a hotel over 90% of its daily budget degrades, leaving room for translation" do
      @hotel.update!(ai_daily_token_budget: 1_000)
      AiRun.create!(hotel: @hotel, kind: :reply, status: :success, input_tokens: 900, output_tokens: 0)

      perform

      assert_degraded(status: "budget_blocked", reason: "budget_exhausted")
    end

    test "a hotel under budget is answered normally" do
      @hotel.update!(ai_daily_token_budget: 1_000)
      AiRun.create!(hotel: @hotel, kind: :reply, status: :success, input_tokens: 500, output_tokens: 0)
      @fake.script_text("Still answering.")

      perform

      assert_equal "assistant", @conversation.messages.order(:id).last.sender_role
    end

    # --- Degradation ------------------------------------------------------------

    test "a timeout tells the guest a person will reply, in the guest's own language" do
      @fake.script_timeout

      perform

      notice = assert_degraded(status: "timeout", reason: "ai_unavailable")
      assert_equal I18n.t("degraded.reception_will_reply", locale: :bs), notice.body
      assert_not_equal I18n.t("degraded.reception_will_reply", locale: :en), notice.body
    end

    test "a refusal degrades too — a 200 with no usable text is still no answer" do
      @fake.script_refusal

      perform

      assert_degraded(status: "refusal", reason: "ai_unavailable")
    end

    test "a degraded conversation is still waiting on a receptionist" do
      @conversation.update!(staff_unread_count: 2)
      @fake.script_timeout

      perform

      assert_equal 2, @conversation.reload.staff_unread_count,
                   "nothing answered the guest, so the receptionist's signal must survive"
      assert @conversation.needs_attention?
    end

    # --- The breaker ------------------------------------------------------------

    test "repeated timeouts open the breaker, and the next guest is degraded instantly" do
      Ai::CircuitBreaker::FAILURE_THRESHOLD.times do |i|
        @conversation.messages.create!(hotel: @hotel, sender_role: :guest, body: "Question #{i}")
        @fake.script_timeout
        perform
      end

      assert @breaker.open?
      assert_equal Ai::CircuitBreaker::FAILURE_THRESHOLD, AiRun.where(status: :timeout).count
    end

    test "a refusal does not open the breaker" do
      (Ai::CircuitBreaker::FAILURE_THRESHOLD + 2).times do |i|
        @conversation.messages.create!(hotel: @hotel, sender_role: :guest, body: "Question #{i}")
        @fake.script_refusal
        perform
      end

      assert @breaker.closed?, "the model declining is not the API being down"
    end

    test "a successful answer clears the failure streak" do
      (Ai::CircuitBreaker::FAILURE_THRESHOLD - 1).times do |i|
        @conversation.messages.create!(hotel: @hotel, sender_role: :guest, body: "Question #{i}")
        @fake.script_timeout
        perform
      end

      @conversation.messages.create!(hotel: @hotel, sender_role: :guest, body: "And again?")
      @fake.script_text("Here you go.")
      perform

      @conversation.messages.create!(hotel: @hotel, sender_role: :guest, body: "One more?")
      @fake.script_timeout
      perform

      assert @breaker.closed?
    end

    # --- Acceptance scenario 12 ---------------------------------------------------

    # The promise the whole product rests on. With the model raising on every
    # call, the guest keeps typing, every message persists, every message
    # reaches the inbox, and a receptionist can answer.
    test "with the model down entirely, the guest still reaches reception" do
      3.times do |i|
        message = @conversation.post_guest_message!(body: "Question #{i}", client_message_id: SecureRandom.uuid)
        assert message.persisted?

        @fake.script_error(Ai::ApiError.new("everything is on fire", status: 500))
        perform
      end

      @conversation.reload
      assert_equal 3, @conversation.messages.where(sender_role: :guest, body: [ "Question 0", "Question 1", "Question 2" ]).count
      assert @conversation.escalated?
      assert @conversation.needs_attention?, "the inbox has to show this to a receptionist"
      assert_includes @hotel.conversations.needs_attention, @conversation

      reply = @conversation.post_staff_message!(user: users(:stari_admin), body: "Sorry for the wait — how can I help?")
      assert reply.persisted?, "a person can always answer, whatever the model is doing"
    end

    private

    def perform
      Ai::GenerateReplyJob.perform_now(@conversation, client: @fake, breaker: @breaker)
      @conversation.reload
    end

    def assert_degraded(status:, reason:)
      notice = @conversation.messages.order(:id).last

      assert_equal "system", notice.sender_role
      assert notice.guest_visible?, "the guest is the one who needs to know a person is coming"
      assert @conversation.escalated?
      assert_equal reason, @conversation.escalation_reason
      assert_equal status, AiRun.order(:id).last.status

      notice
    end
  end
end
