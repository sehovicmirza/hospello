require "test_helper"

module Ai
  # Tools are the only way the assistant can change anything in this system,
  # which makes this the boundary where a successful prompt injection would
  # have to cash out. Everything here is about that: the hotel and the
  # conversation come from the job's own context and are structurally
  # unreachable from the model's output, and every argument that *does* come
  # from the model is validated before it touches a record.
  class ToolsTest < ActiveSupport::TestCase
    # The tenant is set for the whole test, exactly as ApplicationJob sets it
    # around every perform — these tools only ever run inside a job. The global
    # teardown in test_helper.rb clears it again.
    setup do
      @hotel = hotels(:stari_grad)
      ActsAsTenant.current_tenant = @hotel
      @conversation = conversations(:stari_conversation)
    end

    test "the definitions are the two tools this slice ships" do
      assert_equal %w[escalate_to_staff log_unanswered_question], Ai::Tools.definitions.map { |tool| tool[:name] }

      Ai::Tools.definitions.each do |tool|
        assert tool[:description].present?, "#{tool[:name]} needs a description — the model reads it"
        assert_equal "object", tool[:input_schema][:type]
      end
    end

    # --- escalate_to_staff ----------------------------------------------------

    test "escalating marks the conversation for a human and says why in the transcript" do
      result = execute("escalate_to_staff", reason: "guest_requested", summary: "Wants to speak to a person.")

      @conversation.reload
      assert @conversation.escalated?
      assert_equal "guest_requested", @conversation.escalation_reason
      assert @conversation.escalated_at.present?
      assert_not result[:is_error]

      note = @conversation.messages.where(sender_role: :system).last
      assert note.internal?, "the handover note is staff commentary, not something the guest asked about"
      assert_includes note.body, "Wants to speak to a person."
    end

    # The model may emit any string it likes. Only the reasons a model is
    # allowed to choose are accepted; the rest of the enum (ai_unavailable,
    # budget_exhausted, staff_manual) describes things the *system* decided,
    # and letting a model claim one would corrupt the only record of why the
    # AI stopped answering.
    test "an unrecognised reason falls back to ai_uncertain rather than being trusted" do
      execute("escalate_to_staff", reason: "staff_manual", summary: "x")

      assert_equal "ai_uncertain", @conversation.reload.escalation_reason
    end

    test "a missing summary is refused with an error the model can act on" do
      result = execute("escalate_to_staff", reason: "guest_requested")

      assert result[:is_error]
      assert_match(/summary/i, result[:content])
      assert_not @conversation.reload.escalated?
    end

    test "an over-long summary is truncated rather than rejected" do
      execute("escalate_to_staff", reason: "ai_uncertain", summary: "a" * 5_000)

      note = @conversation.reload.messages.where(sender_role: :system).last
      assert_operator note.body.length, :<=, Message::MAX_BODY_LENGTH
    end

    # --- log_unanswered_question ----------------------------------------------

    test "logging a gap records it against this hotel" do
      result = execute(
        "log_unanswered_question",
        question: "Is there a swimming pool?", question_original: "Ima li bazen?"
      )

      assert_not result[:is_error]
      gap = UnansweredQuestion.order(:id).last
      assert_equal "Is there a swimming pool?", gap.question
      assert_equal "Ima li bazen?", gap.question_original
      assert_equal @conversation, gap.conversation
      assert_equal "bs", gap.locale, "the guest's own language, taken from the conversation"
    end

    test "the same gap logged twice counts rather than duplicating" do
      2.times { execute("log_unanswered_question", question: "Is there a swimming pool?") }

      assert_equal 1, UnansweredQuestion.count
      assert_equal 2, UnansweredQuestion.last.asked_count
    end

    test "a blank question is refused" do
      result = execute("log_unanswered_question", question: "   ")

      assert result[:is_error]
      assert_equal 0, UnansweredQuestion.count
    end

    # --- The boundary itself ----------------------------------------------------

    # The decisive one. A prompt injection that makes the model emit a
    # different hotel id, conversation id or guest name must be structurally
    # incapable of doing anything, because none of those are arguments.
    test "identifiers in the model's output are ignored entirely" do
      execute(
        "escalate_to_staff",
        reason: "guest_requested", summary: "hi",
        hotel_id: hotels(:vrelo).id, conversation_id: conversations(:vrelo_conversation).id,
        hotel: hotels(:vrelo), guest_name: "Someone else"
      )

      assert @conversation.reload.escalated?
      other = with_tenant(hotels(:vrelo)) { conversations(:vrelo_conversation).reload }
      assert_not other.escalated?, "the other hotel's conversation must be untouchable from a tool argument"
    end

    # The same for the gap log — and worth being precise about what protects
    # it. Unlike the escalation above, this one cannot be broken from inside
    # this class: UnansweredQuestion is tenant-scoped, so acts_as_tenant writes
    # it to the job's tenant no matter what hotel the code here passes. It was
    # verified by deliberately looking the hotel up from the model's own
    # argument, and the row still landed in the right hotel. This test is
    # therefore a regression guard against a future tool taking a hotel
    # parameter, not a check on today's implementation.
    test "the same is true of the gap log" do
      execute("log_unanswered_question", question: "Anything", hotel_id: hotels(:vrelo).id)

      assert_equal 1, UnansweredQuestion.count
      assert_equal 0, with_tenant(hotels(:vrelo)) { UnansweredQuestion.count }
    end

    # Models invent tool names. An exception here would take down the whole
    # reply and the guest would get the degradation message for what is really
    # a recoverable mistake the model can correct on the next turn.
    test "an unknown tool comes back as an error, not an exception" do
      result = execute("delete_all_the_rooms", {})

      assert result[:is_error]
      assert_match(/unknown tool/i, result[:content])
    end

    test "a result carries the id of the call it answers" do
      call = Ai::Result::ToolCall.new(id: "toolu_abc", name: "log_unanswered_question", input: { question: "Pool?" })

      result = Ai::Tools.new(conversation: @conversation).execute(call)

      assert_equal "tool_result", result[:type]
      assert_equal "toolu_abc", result[:tool_use_id]
    end

    # Models add arguments that were never in the schema. Ignoring them is the
    # only safe reading — the alternative is a tool call that fails for a
    # reason the guest ends up paying for.
    test "an argument that is not in the schema is ignored, not fatal" do
      result = execute("escalate_to_staff", reason: "ai_uncertain", summary: "No idea", urgency: "maximum")

      assert_not result[:is_error]
      assert @conversation.reload.escalated?
    end

    private

    def execute(name, input = {})
      call = Ai::Result::ToolCall.new(id: "toolu_test", name: name, input: input)
      Ai::Tools.new(conversation: @conversation).execute(call)
    end
  end
end
