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

    test "the definitions are the five tools the assistant may use" do
      assert_equal %w[escalate_to_staff propose_service_request confirm_service_request log_unanswered_question
                      set_guest_room],
                   Ai::Tools.definitions.map { |tool| tool[:name] }

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

    # --- set_guest_room --------------------------------------------------------
    #
    # The one tool that exists for WhatsApp, where a guest arrives with neither
    # a room nor a name — there is no entry form on that channel and no cookie
    # to read one back from. Everything here is about the same question the
    # rest of this file asks: the model supplies the arguments, and the model
    # supplies *only* the arguments. Which session gets bound is decided by the
    # conversation this Tools instance was constructed with, and there is no
    # argument that can reach it.

    test "a roomless guest is bound to the room and name they gave" do
      roomless = whatsapp_conversation

      result = execute_on(roomless, "set_guest_room", { room_number: "301", guest_name: "Amira Hodžić" })

      assert_not result[:is_error], result[:content]
      session = roomless.guest_session.reload
      assert_equal rooms(:stari_301), session.room
      assert_equal "Amira Hodžić", session.guest_name
      # The conversation's own room matters as much as the session's: the
      # prompt reads one (Ai::PromptBuilder) and a confirmed request reads the
      # other (ServiceRequestDraft#build_request).
      assert_equal rooms(:stari_301), roomless.reload.room
    end

    # Nothing about self-declaring a room number over WhatsApp is more
    # trustworthy than typing one into a form under a QR code anybody in the
    # building can scan. GuestSession#force_unverified_identity is what makes
    # this true regardless of what any caller intends; this pins that the new
    # write path did not become the exception.
    test "binding a room leaves the guest exactly as unverified as before" do
      roomless = whatsapp_conversation

      execute_on(roomless, "set_guest_room", { room_number: "301", guest_name: "Amira" })

      assert roomless.guest_session.reload.unverified?
    end

    # An error the model can act on, not an exception: it has to be able to
    # tell the guest the number was not found and ask again. A typo is the
    # overwhelmingly common case here.
    test "a room number this hotel does not have comes back as a correctable error" do
      roomless = whatsapp_conversation

      result = execute_on(roomless, "set_guest_room", { room_number: "9999", guest_name: "Amira" })

      assert result[:is_error]
      assert_match "9999", result[:content]
      assert_nil roomless.guest_session.reload.room_id
    end

    # The injection shape this task exists to refuse, from the other side: a
    # room that is real, but somebody else's.
    #
    # **Held by two independent layers**, which is worth knowing before anyone
    # decides one is redundant. Hotel#find_active_room is tenant-scoped, so
    # from inside this hotel a foreign room and an invented one are
    # indistinguishable; and GuestSession#room_must_belong_to_the_same_hotel
    # re-queries Room by id on save, so even a room object handed straight in
    # is refused. Measured: replacing find_active_room with a raw cross-hotel
    # find_by_sql leaves this test **green** (the validation catches it, and
    # Tools#execute turns the RecordInvalid into an error tool_result);
    # removing the validation as well turns it red.
    test "a room belonging to another hotel is refused exactly like one that does not exist" do
      roomless = whatsapp_conversation
      foreign = with_tenant(hotels(:vrelo)) { rooms(:vrelo_401) }

      result = execute_on(roomless, "set_guest_room", { room_number: foreign.number, guest_name: "Amira" })

      assert result[:is_error]
      assert_nil roomless.guest_session.reload.room_id
      assert_equal foreign.reload.id, with_tenant(hotels(:vrelo)) { rooms(:vrelo_401).id }
    end

    # A guest whose room is already known — every web guest, and any WhatsApp
    # guest who has already answered. Re-binding is not a thing this tool is
    # for: the room is what a receptionist delivers to and what every open
    # request is addressed to, and moving it mid-conversation on a model's say-so
    # is exactly the kind of quiet change nobody would notice until a towel went
    # to the wrong door.
    test "a guest whose room is already known cannot be moved" do
      result = execute("set_guest_room", room_number: "302", guest_name: "Someone Else")

      assert result[:is_error]
      assert_equal rooms(:stari_301), @conversation.guest_session.reload.room
      assert_equal "Amira Fixture", @conversation.guest_session.guest_name
    end

    # Two layers again, and measured the same way: removing this tool's own
    # blank check leaves the test green, because GuestSession still validates
    # guest_name's presence and Tools#execute converts that RecordInvalid into
    # an error the model can act on. Removing both turns it red. The tool-level
    # check earns its keep by producing a message written *for the model*
    # ("ask the guest what to call them") rather than a relayed
    # ActiveRecord sentence.
    test "a blank name is refused rather than written over the one already there" do
      roomless = whatsapp_conversation
      before = roomless.guest_session.guest_name

      result = execute_on(roomless, "set_guest_room", { room_number: "301", guest_name: "  " })

      assert result[:is_error]
      assert_equal before, roomless.guest_session.reload.guest_name
    end

    # The first moment anyone knows what language this guest speaks. There is
    # no Accept-Language on WhatsApp and no form, so a session starts on the
    # app's default — which means the staff-facing translation is being asked
    # to translate *from* the wrong source language until this corrects it.
    test "the guest's own language is recorded, on the conversation as well as the session" do
      roomless = whatsapp_conversation

      execute_on(roomless, "set_guest_room", { room_number: "301", guest_name: "Amira", language: "de" })

      assert_equal "de", roomless.guest_session.reload.locale
      # guest_locale is only copied from the session `on: :create`, so the live
      # conversation has to be told separately or every message keeps being
      # stamped with the language the guest does not speak.
      assert_equal "de", roomless.reload.guest_locale
    end

    test "a language this app does not support is ignored rather than written" do
      roomless = whatsapp_conversation

      result = execute_on(roomless, "set_guest_room", { room_number: "301", guest_name: "Amira", language: "kl" })

      assert_not result[:is_error], "an unsupported language is not worth failing the whole binding over"
      assert_equal "en", roomless.guest_session.reload.locale
    end

    # The structural half of "ask for the room first". The prompt tells the
    # model to; this makes it true whatever the model was talked into. A request
    # that cannot be delivered to a room is worse than no request — it reaches a
    # board with nowhere to send it.
    test "no request can be started for a guest whose room is still unknown" do
      roomless = whatsapp_conversation

      result = execute_on(roomless, "propose_service_request", { category_key: request_categories(:stari_towels).key, details: { quantity: "2" } })

      assert result[:is_error]
      assert_match "set_guest_room", result[:content]
      assert_equal 0, roomless.service_request_drafts.count
    end

    private

    # Positional hash, not keywords: a tool's input really is one JSON object,
    # and keyword-splatting it here would make `execute("x", reason: "y")`
    # indistinguishable from a helper option.
    def execute(name, input = {}) = execute_on(@conversation, name, input)

    def execute_on(conversation, name, input = {})
      call = Ai::Result::ToolCall.new(id: "toolu_test", name: name, input: input)
      Ai::Tools.new(conversation: conversation).execute(call)
    end

    # A WhatsApp guest as Whatsapp::InboundRouter really creates one: no room,
    # no token, identified only by a phone number. Built through the same
    # GuestSession.for_whatsapp the router uses rather than assembled by hand,
    # so this cannot drift from what production actually produces.
    def whatsapp_conversation
      session = GuestSession.for_whatsapp(
        phone_e164: "+38761234567", name: "+38761234567", accepted_at: Time.current
      )
      Conversation.live_for(session)
    end
  end
end
