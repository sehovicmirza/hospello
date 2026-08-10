require "test_helper"

module Ai
  # One real call to the real API, run by hand before a release — never in CI.
  #
  #   LIVE_AI=1 ANTHROPIC_API_KEY=sk-ant-... bin/rails test test/services/ai/live_smoke_test.rb
  #
  # Why this exists when everything else is mocked: WebMock proves we send what
  # we think we send, but it cannot tell us the API still accepts it. Parameter
  # names change, `output_config` grows a constraint, a model id is retired.
  # Those failures are invisible to a mocked suite and total in production, and
  # they surface here in about twenty seconds.
  #
  # It asserts the three things that would be silently wrong for weeks:
  # a grounded answer, a real tool call, and — the one nothing else can check —
  # that prompt caching is actually engaging on the second call.
  class LiveSmokeTest < ActiveSupport::TestCase
    # Big enough that the cached prefix clears the API's minimum cacheable
    # length; below that threshold `cache_control` is accepted and quietly does
    # nothing, which would make the caching assertion below pass for the wrong
    # reason on a short prompt.
    KNOWLEDGE = ([ "<kb_entry id=\"1\" category=\"dining\">Breakfast is served in the Orangerie " \
                   "from 07:00 to 10:30 every day, including weekends.</kb_entry>" ] +
                 (2..200).map do |id|
                   "<kb_entry id=\"#{id}\" category=\"facilities\">Filler entry #{id}: the hotel has " \
                   "a lift, a luggage room, and a small library on the second floor.</kb_entry>"
                 end).join("\n").freeze

    RULES = "You are a hotel concierge. Answer only from <hotel_knowledge>. If the answer is not " \
            "there, say so and call escalate_to_staff. Never invent a time, a price or a policy.".freeze

    ESCALATE_TOOL = {
      name: "escalate_to_staff",
      description: "Hand the conversation to a human receptionist.",
      input_schema: {
        type: "object",
        properties: { reason: { type: "string" } },
        required: [ "reason" ]
      }
    }.freeze

    setup do
      skip "Set LIVE_AI=1 to run the live API smoke test" unless ENV["LIVE_AI"] == "1"
      skip "ANTHROPIC_API_KEY is not set" if ENV["ANTHROPIC_API_KEY"].blank?

      WebMock.allow_net_connect!
      @client = Ai::Client.new(api_key: ENV["ANTHROPIC_API_KEY"])
    end

    teardown do
      WebMock.disable_net_connect!(allow_localhost: true)
    end

    test "answers from the knowledge base, calls a real tool, and caches the prefix" do
      first = @client.chat(system: system_blocks, messages: [ ask("When is breakfast served?") ])

      assert_equal "end_turn", first.stop_reason, "expected a plain answer, got #{first.stop_reason}"
      assert_match(/07:00|7:00|7 ?am/i, first.text, "the answer should come from the knowledge base")

      # Something the knowledge base has no answer for. The grounding rules say
      # escalate rather than guess, and this is the only place we find out
      # whether a real model actually does.
      second = @client.chat(
        system: system_blocks,
        messages: [ ask("Can you confirm a late check-out at 6pm for me?") ],
        tools: [ ESCALATE_TOOL ]
      )

      assert second.tool_calls?, "expected an escalation, got: #{second.text.inspect}"
      assert_equal "escalate_to_staff", second.tool_calls.first.name
      assert second.tool_calls.first.input["reason"].present?

      # The point of the whole stable-then-volatile block ordering. The first
      # call writes the cache; this asserts the second one read it back.
      assert second.usage.cached?,
             "no cache read on the second call (cache_read_input_tokens was " \
             "#{second.usage.cache_read_input_tokens}) — the cached prefix is not stable"
    end

    private

    # Volatile content last, after the cache breakpoint, exactly as the prompt
    # builder will order it.
    def system_blocks
      [
        { text: RULES, cache: false },
        { text: "<hotel_knowledge>\n#{KNOWLEDGE}\n</hotel_knowledge>", cache: true },
        { text: "Current local time: 09:15. Guest: Ana, room 204 (unverified).", cache: false }
      ]
    end

    def ask(question) = { role: "user", content: "<guest_message>#{question}</guest_message>" }
  end
end
