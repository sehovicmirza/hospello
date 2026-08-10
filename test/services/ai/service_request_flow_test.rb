require "test_helper"

module Ai
  # The acceptance scenario, driven through the real job with FakeClaude in
  # place of the model: "can I get two extra towels" → one question → "bath
  # towels" → a summary → "yes" → **exactly one** request.
  #
  # Every assertion is on the database rather than the transcript. What the
  # model says is the model's business; what this slice promises is that
  # nothing reaches a receptionist that the guest did not agree to, and that
  # what they did agree to reaches them exactly once.
  class ServiceRequestFlowTest < ActiveJob::TestCase
    setup do
      @hotel = hotels(:stari_grad)
      ActsAsTenant.current_tenant = @hotel
      @conversation = conversations(:stari_conversation)
      @category = request_categories(:stari_towels) # needs quantity, description
      @fake = FakeClaude.new
    end

    test "gather, ask, summarise, confirm — one request at the end of it" do
      # Turn 1: the guest says what they want, but not everything about it.
      guest_says("Can I get two extra towels?")
      @fake
        .script_tool_call("propose_service_request", { "category_key" => @category.key, "details" => { "quantity" => "2" } })
        .script_text("Of course — what kind of towels?")
      run_job

      draft = ServiceRequestDraft.live_for(@conversation)
      assert draft.status_gathering?, "nothing has been shown to the guest yet"
      assert_equal [ "description" ], draft.missing_fields
      assert_equal 0, ServiceRequest.count

      # Turn 2: they answer, and now there is something to agree to.
      guest_says("Bath towels please")
      @fake
        .script_tool_call("propose_service_request",
                          { "category_key" => @category.key, "details" => { "description" => "bath towels" } })
        .script_text("Two bath towels for room 301 — shall I send that to reception?")
      run_job

      draft.reload
      assert draft.status_awaiting_confirmation?
      assert_equal({ "quantity" => "2", "description" => "bath towels" }, draft.details)
      assert_equal 0, ServiceRequest.count, "a summary is not a request"

      # Turn 3: the guest agrees.
      guest_says("yes please")
      @fake
        .script_tool_call("confirm_service_request", { "draft_id" => draft.id })
        .script_text("Sent to reception — someone will bring them up.")
      run_job

      request = ServiceRequest.sole
      assert_equal @category, request.request_category
      assert_equal({ "quantity" => "2", "description" => "bath towels" }, request.details)
      assert_equal @conversation.guest_session.room, request.room
      assert request.status_new?, "the hotel has not agreed to anything yet — a person still has to"
      assert draft.reload.status_confirmed?
    end

    # The guest changing their mind is the case that separates "gather and
    # propose" from "decide on the guest's behalf".
    test "a guest who says no leaves nothing behind" do
      draft = awaiting_confirmation_draft

      guest_says("no, forget it")
      @fake.script_text("No problem — let me know if you change your mind.")
      run_job

      assert_equal 0, ServiceRequest.count
      assert draft.reload.status_awaiting_confirmation?, "still open in case they change their mind, and it expires on its own"
    end

    # A model can emit the same tool call twice in one turn. The guest asked
    # once, so the hotel gets one request.
    test "confirming twice in one turn still produces one request" do
      draft = awaiting_confirmation_draft

      guest_says("yes")
      @fake.script_tool_calls([
        { name: "confirm_service_request", input: { "draft_id" => draft.id } },
        { name: "confirm_service_request", input: { "draft_id" => draft.id } }
      ])
      @fake.script_text("Sent to reception.")
      run_job

      assert_equal 1, ServiceRequest.count
    end

    test "confirming across two turns still produces one request" do
      draft = awaiting_confirmation_draft

      guest_says("yes")
      @fake.script_tool_call("confirm_service_request", { "draft_id" => draft.id }).script_text("Sent.")
      run_job

      guest_says("did that go through?")
      @fake.script_tool_call("confirm_service_request", { "draft_id" => draft.id }).script_text("It did.")
      run_job

      assert_equal 1, ServiceRequest.count
    end

    # The whole promise, from the other end: no amount of tool-calling can
    # produce a request the guest never agreed to.
    test "the assistant cannot confirm a request the guest has not been shown" do
      guest_says("towels")
      @fake
        .script_tool_call("propose_service_request", { "category_key" => @category.key, "details" => { "quantity" => "2" } })
        .script_tool_call("confirm_service_request", {})
        .script_text("Let me check that with you first.")
      run_job

      assert_equal 0, ServiceRequest.count
      assert ServiceRequestDraft.live_for(@conversation).status_gathering?
    end

    # A model naming a draft that is not the one in front of the guest is
    # confused about what it is confirming, and confirming the wrong thing on
    # someone's behalf is the exact failure this slice exists to prevent. It
    # refuses rather than quietly doing the right thing for the wrong reason.
    test "confirming a draft id that is not this conversation's is refused" do
      draft = awaiting_confirmation_draft

      guest_says("yes")
      @fake.script_tool_call("confirm_service_request", { "draft_id" => draft.id + 999 }).script_text("Hmm.")
      run_job

      assert_equal 0, ServiceRequest.count
      assert draft.reload.status_awaiting_confirmation?
      assert_match(/is not the pending request/i, tool_result_content)
    end

    # An inactive category is one the hotel has switched off. It must not be
    # offerable, however the guest phrases the ask.
    test "a category the hotel has switched off cannot be proposed" do
      @category.update!(active: false)

      guest_says("towels")
      @fake
        .script_tool_call("propose_service_request", { "category_key" => @category.key, "details" => {} })
        .script_text("I'll pass that on.")
      run_job

      assert_nil ServiceRequestDraft.live_for(@conversation)
    end

    test "a category this hotel does not offer is refused, and no category is invented" do
      guest_says("I want a helicopter")
      @fake
        .script_tool_call("propose_service_request", { "category_key" => "helicopter", "details" => {} })
        .script_text("I'll pass that to reception.")
      run_job

      assert_nil ServiceRequestDraft.live_for(@conversation)
      assert_equal 2, @hotel.request_categories.count, "no category was created"
      assert_match(/unknown category_key/i, tool_result_content)
    end

    # Another hotel's category key is exactly as unknown as an invented one.
    test "another hotel's category key is not usable here" do
      other_key = with_tenant(hotels(:vrelo)) { request_categories(:vrelo_wakeup).key }
      # Same key exists at both hotels, so use one that does not.
      with_tenant(hotels(:vrelo)) do
        hotels(:vrelo).request_categories.create!(key: "vrelo_only", name: "Vrelo only", detail_fields: [])
      end

      guest_says("something")
      @fake
        .script_tool_call("propose_service_request", { "category_key" => "vrelo_only", "details" => {} })
        .script_text("I'll pass that on.")
      run_job

      assert_nil ServiceRequestDraft.live_for(@conversation)
      assert_equal "wake_up_call", other_key, "precondition: the shared key is not the one under test"
    end

    # `details` ends up on a receptionist's card and inside the dedupe key.
    # A model writing arbitrary keys into it would make both unpredictable.
    test "details the category never asked for are dropped" do
      guest_says("towels")
      @fake
        .script_tool_call("propose_service_request", {
          "category_key" => @category.key,
          "details" => { "quantity" => "2", "description" => "bath", "room_id" => "999", "vip" => "true" }
        })
        .script_text("Shall I send that?")
      run_job

      assert_equal({ "quantity" => "2", "description" => "bath" }, ServiceRequestDraft.live_for(@conversation).details)
    end

    test "a later turn adds to the request rather than replacing it" do
      guest_says("towels")
      @fake
        .script_tool_call("propose_service_request", { "category_key" => @category.key, "details" => { "quantity" => "2" } })
        .script_text("What kind?")
      run_job

      guest_says("bath ones")
      @fake
        .script_tool_call("propose_service_request", { "category_key" => @category.key, "details" => { "description" => "bath" } })
        .script_text("Shall I send that?")
      run_job

      assert_equal({ "quantity" => "2", "description" => "bath" }, ServiceRequestDraft.live_for(@conversation).details)
    end

    # The prompt has to carry the pending draft, or a guest replying "yes" to
    # a summary card gives the model nothing to go on and it starts over.
    test "the pending request travels into the next prompt" do
      draft = awaiting_confirmation_draft

      guest_says("yes")
      @fake.script_text("ok")
      run_job

      assert_match(/<pending_draft id="#{draft.id}"/, @fake.prompt_text)
      assert_includes @fake.prompt_text, draft.summary_for_guest
    end

    test "the hotel's own categories are in the prompt and another hotel's are not" do
      with_tenant(hotels(:vrelo)) do
        hotels(:vrelo).request_categories.create!(
          key: "vrelo_helipad", name: "Helipad transfer at Vrelo Bosne", detail_fields: []
        )
      end

      guest_says("hello")
      @fake.script_text("hi")
      run_job

      assert_match(/<category key="room_items"/, @fake.prompt_text)
      assert_not_includes @fake.prompt_text, "vrelo_helipad"
      assert_not_includes @fake.prompt_text, "Helipad transfer"
    end

    private

    def guest_says(body)
      @conversation.messages.create!(hotel: @hotel, sender_role: :guest, body: body)
    end

    def run_job
      Ai::GenerateReplyJob.perform_now(@conversation, client: @fake)
      @conversation.reload
    end

    def awaiting_confirmation_draft
      @conversation.service_request_drafts.create!(
        request_category: @category, status: :awaiting_confirmation,
        details: { "quantity" => "2", "description" => "bath towels" }
      )
    end

    # The tool_result the concierge sent back to the model on the last turn —
    # how a test reads what the server actually told it.
    def tool_result_content
      @fake.calls.last[:messages].flat_map { |message| Array(message[:content]) }
           .select { |block| block.is_a?(Hash) && block[:type] == "tool_result" }
           .map { |block| block[:content] }.join("\n")
    end
  end
end
