require "test_helper"

module Ai
  # One concierge turn, end to end, against FakeClaude — no network anywhere.
  #
  # The concierge owns the loop (ask, run tools, ask again) and the two things
  # that must happen between the model's output and the guest's screen: the
  # citation marker is stripped, and a reply that is not a real reply — a
  # refusal, a truncation, an empty string — is never posted as if it were.
  class ConciergeTest < ActiveSupport::TestCase
    setup do
      @hotel = hotels(:stari_grad)
      ActsAsTenant.current_tenant = @hotel
      @conversation = conversations(:stari_conversation)
      @fake = FakeClaude.new
    end

    test "answers the guest from the hotel's own knowledge" do
      @fake.script_text("Doručak je od 07:00 do 10:30.", input_tokens: 4_000, output_tokens: 20)

      outcome = concierge_reply

      assert outcome.replied?
      assert_equal "Doručak je od 07:00 do 10:30.", outcome.text
      assert_equal 4_000, outcome.usage.input_tokens
    end

    test "the prompt it sends is the one the prompt builder builds" do
      @fake.script_text("ok")

      concierge_reply

      call = @fake.last_call
      assert_includes call[:system].map { |block| block[:text] }.join, "<hotel_knowledge>"
      assert_equal Ai::Tools.names, call[:tools].map { |tool| tool[:name] }
      assert_includes @fake.prompt_text, "Do you have extra towels?"
    end

    # The citation marker is our own invention and exists purely so an AiRun
    # can say which entries did the work. A guest seeing "[kb: 12]" at the end
    # of a message would rightly conclude the software is broken.
    test "the citation marker is recorded and stripped before the guest sees it" do
      @fake.script_text("Doručak je od 07:00 do 10:30.\n[kb: #{kb_entries(:stari_breakfast).id}, 999]")

      outcome = concierge_reply

      assert_equal "Doručak je od 07:00 do 10:30.", outcome.text
      assert_equal [ kb_entries(:stari_breakfast).id ], outcome.cited_kb_entry_ids,
                   "an id that is not this hotel's published entry is dropped, not recorded"
    end

    test "a reply with no citation marker is left exactly as written" do
      @fake.script_text("Hello! How can I help?")

      outcome = concierge_reply

      assert_equal "Hello! How can I help?", outcome.text
      assert_empty outcome.cited_kb_entry_ids
    end

    # --- The tool loop ---------------------------------------------------------

    test "runs a tool the model asks for, then sends the result back for a final answer" do
      @fake
        .script_tool_call("log_unanswered_question", { "question" => "Is there a pool?" })
        .script_text("I don't have that written down — I'll pass it to reception.")

      outcome = concierge_reply

      assert outcome.replied?
      assert_equal "I don't have that written down — I'll pass it to reception.", outcome.text
      assert_equal 1, UnansweredQuestion.count
      assert_equal 2, @fake.call_count

      # The second call has to carry the tool result, or the model is answering
      # the same question again with no idea it already acted.
      second = @fake.calls.last[:messages].last
      assert_equal "user", second[:role]
      assert_equal "tool_result", second[:content].first[:type]
    end

    test "usage is summed across every call in the turn" do
      @fake
        .script_tool_call("log_unanswered_question", { "question" => "Pool?" })
        .script_text("Passing that on.", input_tokens: 100, output_tokens: 30, cache_read_input_tokens: 90)

      outcome = concierge_reply

      assert_equal 100, outcome.usage.input_tokens
      assert_equal 30, outcome.usage.output_tokens
      assert_equal 90, outcome.usage.cache_read_input_tokens
    end

    # An unbounded loop is an unbounded bill and a guest watching a typing
    # indicator forever. The cap is low on purpose: this slice ships two tools
    # and no legitimate turn needs more rounds than this.
    test "the tool loop is bounded" do
      (Ai::Concierge::MAX_TOOL_ROUNDS + 2).times do
        @fake.script_tool_call("log_unanswered_question", { "question" => "Pool?" })
      end
      @fake.script_text("Sorry, I'll pass this to reception.")

      concierge_reply

      assert_operator @fake.call_count, :<=, Ai::Concierge::MAX_TOOL_ROUNDS + 1
    end

    test "a tool failure comes back to the model rather than ending the turn" do
      @fake
        .script_tool_call("nonexistent_tool", {})
        .script_text("Let me pass that to reception instead.")

      outcome = concierge_reply

      assert outcome.replied?
      assert_equal "Let me pass that to reception instead.", outcome.text
    end

    # --- Replies that are not replies --------------------------------------------

    test "a refusal is not a reply" do
      @fake.script_refusal

      outcome = concierge_reply

      assert_not outcome.replied?
      assert_equal :refusal, outcome.status
    end

    # Thinking and visible text share the max_tokens budget, so this is
    # reachable with an ordinary cap — and half a sentence about a hotel policy
    # is worse than no sentence at all.
    test "a truncated answer is not a reply" do
      @fake.script_truncated("Breakfast is served from")

      outcome = concierge_reply

      assert_not outcome.replied?
      assert_equal :api_error, outcome.status
    end

    test "an empty answer is not a reply" do
      @fake.script_text("   ")

      outcome = concierge_reply

      assert_not outcome.replied?
    end

    # A turn that spent itself entirely on tool calls has nothing to say, and
    # posting "" to a guest is worse than the degradation message.
    test "a loop that runs out of rounds with nothing to say is not a reply" do
      (Ai::Concierge::MAX_TOOL_ROUNDS + 1).times do
        @fake.script_tool_call("log_unanswered_question", { "question" => "Pool?" })
      end

      outcome = concierge_reply

      assert_not outcome.replied?
    end

    # --- Failures the caller has to tell apart -------------------------------------

    test "a timeout is reported as a timeout, not swallowed" do
      @fake.script_timeout

      outcome = concierge_reply

      assert_not outcome.replied?
      assert_equal :timeout, outcome.status
      assert_equal "Ai::TimeoutError", outcome.error_class
    end

    test "a rate limit and a server error both report as api errors" do
      @fake.script_rate_limited
      assert_equal :api_error, concierge_reply.status

      @fake.script_server_error(status: 503)
      assert_equal :api_error, concierge_reply.status
    end

    test "latency and the model used are recorded on every outcome" do
      @fake.script_text("ok")

      outcome = concierge_reply

      assert_equal Rails.configuration.x.ai.model, outcome.model
      assert_not_nil outcome.latency_ms
    end

    private

    def concierge_reply
      Ai::Concierge.new(conversation: @conversation.reload, client: @fake).reply
    end
  end
end
