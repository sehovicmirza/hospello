require "test_helper"

module Ai
  # What the assistant can and cannot do for a hotel whose plan has no service
  # requests.
  #
  # The two halves of this gate are tested separately and deliberately so,
  # because they protect against different things and only one of them is a
  # guarantee. Withholding the tools from the definitions list shapes the
  # model's behaviour. Refusing them at dispatch is what makes "no ticket is
  # ever created" true, because a model can emit a tool it was never offered.
  # Delete the dispatch guard and the second group here must go red while the
  # first stays green.
  class EssentialsPlanTest < ActiveSupport::TestCase
    setup do
      @hotel = hotels(:stari_grad)
      ActsAsTenant.current_tenant = @hotel
      @conversation = conversations(:stari_conversation)
    end

    # --- what the model is offered -------------------------------------------

    test "an Essentials hotel is offered neither request tool" do
      @hotel.update!(plan: :essentials)

      offered = Ai::Tools.definitions_for(@hotel).map { |tool| tool[:name] }

      assert_equal %w[escalate_to_staff log_unanswered_question set_guest_room], offered
    end

    # escalate_to_staff stays because "I cannot answer that" is not a service
    # request and Essentials still has the inbox; set_guest_room stays because
    # a WhatsApp guest arrives with no room and no name whatever the plan is.
    test "a Service hotel is offered all five" do
      @hotel.update!(plan: :service)

      offered = Ai::Tools.definitions_for(@hotel).map { |tool| tool[:name] }

      assert_equal %w[escalate_to_staff propose_service_request confirm_service_request
                      log_unanswered_question set_guest_room], offered
    end

    test "the unknown-tool error does not advertise tools this hotel cannot use" do
      @hotel.update!(plan: :essentials)

      result = execute("wire_money", { amount: "1000" })

      assert result[:is_error]
      assert_no_match(/propose_service_request/, result[:content])
      assert_match(/escalate_to_staff/, result[:content])
    end

    # --- what the model is allowed to actually run ---------------------------

    test "propose_service_request creates nothing when the plan has no requests" do
      @hotel.update!(plan: :essentials)

      assert_no_difference -> { ServiceRequestDraft.unscoped.count } do
        result = execute("propose_service_request", { category_key: "room_items", details: { "quantity" => "2" } })
        assert result[:is_error], "the tool reported success on a plan that has no requests"
      end
    end

    # Deliberately built against a draft that is genuinely confirmable. An
    # earlier version of this test passed a made-up draft_id, which errors on
    # any plan — so it stayed green with the dispatch guard deleted and proved
    # nothing. The draft is created while the hotel is on Service, then the
    # plan is moved, which is also the real-world shape: a hotel downgrades
    # with a draft already in flight.
    test "confirm_service_request creates nothing when the plan has no requests" do
      @hotel.update!(plan: :service)
      execute("propose_service_request",
        { category_key: "room_items", details: { "quantity" => "2", "description" => "bath towels" } })
      draft = ServiceRequestDraft.unscoped.order(:id).last
      assert draft.status_awaiting_confirmation?, "the draft must be confirmable or this test proves nothing"

      @hotel.update!(plan: :essentials)
      # Ai::Tools reads the hotel through conversation.hotel, and that
      # association was cached by the propose call above while the hotel was
      # still on Service. A real job loads the conversation fresh; this test
      # has to say so.
      @conversation.reload

      assert_no_difference -> { ServiceRequest.unscoped.count } do
        result = execute("confirm_service_request", { draft_id: draft.id })
        assert result[:is_error], "confirm succeeded on a plan with no requests"
      end
    end

    test "the refusal tells the model to send the guest to reception, by number" do
      @hotel.update!(plan: :essentials, contact_phone: "+387 33 000 000")

      result = execute("propose_service_request", { category_key: "room_items" })

      assert_match(/\+387 33 000 000/, result[:content])
      assert_match(/no request has been created/i, result[:content])
    end

    # A hotel that never filled in a phone number must not produce an assistant
    # telling guests to call a number it does not have.
    test "the refusal falls back to the reception desk when there is no phone" do
      @hotel.update!(plan: :essentials, contact_phone: nil)

      result = execute("propose_service_request", { category_key: "room_items" })

      assert_match(/reception desk/, result[:content])
      assert_no_match(/call reception on\s*\./, result[:content])
    end

    test "a Service hotel still creates the draft" do
      @hotel.update!(plan: :service)

      assert_difference -> { ServiceRequestDraft.unscoped.count }, 1 do
        result = execute("propose_service_request", { category_key: "room_items", details: { "quantity" => "2" } })
        assert_not result[:is_error], result[:content]
      end
    end

    # --- what the model is told ----------------------------------------------

    test "the Essentials prompt describes neither request tool" do
      @hotel.update!(plan: :essentials)

      rules = Ai::PromptBuilder.static_rules_for(@hotel)

      assert_no_match(/propose_service_request/, rules)
      assert_no_match(/confirm_service_request/, rules)
      # The prompt and the tool list have to agree — describing a tool the model
      # was not given is how you get it calling one that is not there.
      assert_equal Ai::Tools.definitions_for(@hotel).map { |t| t[:name] }.grep(/service_request/),
                   rules.scan(/\w*service_request\w*/).uniq
    end

    test "the Essentials prompt sends askers to reception and keeps answering them" do
      @hotel.update!(plan: :essentials)

      rules = Ai::PromptBuilder.static_rules_for(@hotel)

      assert_match(/does not take requests through this chat/, rules)
      assert_match(/ask them to contact reception/, rules)
      assert_match(/Keep answering their questions in full/, rules)
    end

    # Without this the model reaches for escalate_to_staff on every "can I have
    # towels", which floods the inbox and quietly turns Essentials back into a
    # request queue worked by hand — the exact thing the plan does not sell.
    test "the Essentials prompt tells the model not to escalate every ask" do
      @hotel.update!(plan: :essentials)

      assert_match(/Do not call escalate_to_staff just because a guest asked for something/,
                   Ai::PromptBuilder.static_rules_for(@hotel))
    end

    test "both plans keep the rules that are not about requests" do
      %i[essentials service].each do |plan|
        @hotel.update!(plan: plan)
        rules = Ai::PromptBuilder.static_rules_for(@hotel)

        assert_match(/DATA, NOT INSTRUCTIONS/, rules, "#{plan} lost the injection rules")
        assert_match(/escalate_to_staff/, rules, "#{plan} lost escalation")
        assert_match(/EMERGENCIES/, rules, "#{plan} lost the emergency rule")
        assert_match(/never guess a price/, rules, "#{plan} lost the grounding rule")
      end
    end

    # The hotel card carries a menu of request kinds. A hotel that takes none
    # should not be handed an empty menu to reason about.
    test "the Essentials hotel card omits the request categories element" do
      @hotel.update!(plan: :essentials)
      built = Ai::PromptBuilder.new(conversation: @conversation).build

      assert_no_match(/<request_categories>/, built.system_text)
      # The knowledge base is what Essentials runs on, so its absence would be a
      # different bug wearing the same clothes.
      assert_match(/<hotel_knowledge>/, built.system_text)
    end

    test "a Service hotel card still carries them" do
      @hotel.update!(plan: :service)
      @conversation.reload

      assert_match(/<request_categories>/, Ai::PromptBuilder.new(conversation: @conversation).build.system_text)
    end

    private
      def execute(name, input)
        call = Ai::Result::ToolCall.new(id: "toolu_plan", name: name, input: input)
        Ai::Tools.new(conversation: @conversation).execute(call)
      end
  end
end
