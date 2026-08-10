require "test_helper"

# The fake is the contract every later AI test is written against, so it gets
# tested like production code. This repository has already shipped a batch of
# tests that passed against broken code once; a double that quietly produces
# the wrong shape is how that happens again, at the scale of a whole slice.
#
# The single most important assertion here is the first one: FakeClaude returns
# real Ai::Result objects. The moment it returns anything else — a stub, an
# OpenStruct, a hash — every test above it stops proving anything about the
# code that runs in production.
class FakeClaudeTest < ActiveSupport::TestCase
  setup { @fake = FakeClaude.new }

  test "returns the same type the real client returns" do
    @fake.script_text("Breakfast is served 07:00-10:30.")

    result = @fake.chat(system: [], messages: [])

    assert_instance_of Ai::Result, result
    assert_instance_of Ai::Result::Usage, result.usage
    assert_equal "Breakfast is served 07:00-10:30.", result.text
    assert_equal "end_turn", result.stop_reason
    assert_not result.refusal?
  end

  test "records every call so the prompt itself can be asserted on" do
    @fake.script_text("Ja.").script_text("Nein.")
    system = [ { text: "rules", cache: false }, { text: "<hotel_knowledge>pool</hotel_knowledge>", cache: true } ]

    @fake.chat(system: system, messages: [ { role: "user", content: "Gibt es einen Pool?" } ])
    @fake.chat(system: system, messages: [ { role: "user", content: "Und eine Sauna?" } ])

    assert_equal 2, @fake.call_count
    assert_equal system, @fake.system_blocks(0)
    assert_includes @fake.prompt_text(0), "<hotel_knowledge>pool</hotel_knowledge>"
    assert_includes @fake.prompt_text(1), "Und eine Sauna?"
  end

  # The cross-tenant assertion in Task 3 is written as "this string appears
  # nowhere in the prompt", so #prompt_text has to reach both the system blocks
  # and the conversation history. A version that only flattened the system
  # blocks would make that test pass while hotel B's data sat in the messages.
  test "prompt_text covers the conversation history as well as the system blocks" do
    @fake.script_text("ok")

    @fake.chat(
      system: [ { text: "rules", cache: false } ],
      messages: [ { role: "user", content: "another hotel's secret" } ]
    )

    assert_includes @fake.prompt_text, "another hotel's secret"
  end

  test "scripts a sequence of tool calls followed by a final answer" do
    @fake
      .script_tool_call("escalate_to_staff", { "reason" => "complaint" })
      .script_text("Reception will come up shortly.")

    first = @fake.chat(system: [], messages: [])
    second = @fake.chat(system: [], messages: [])

    assert first.tool_calls?
    assert_equal "tool_use", first.stop_reason
    assert_equal "escalate_to_staff", first.tool_calls.sole.name
    assert_equal "complaint", first.tool_calls.sole.input["reason"]
    assert_not second.tool_calls?
    assert_equal "Reception will come up shortly.", second.text
  end

  test "tool arguments read the same by string and by symbol, as they do from the real client" do
    @fake.script_tool_call("log_unanswered_question", { question: "Is there a pool?" })

    input = @fake.chat(system: [], messages: []).tool_calls.sole.input

    assert_equal "Is there a pool?", input["question"]
    assert_equal "Is there a pool?", input[:question]
  end

  test "tool call ids are deterministic" do
    @fake.script_tool_call("escalate_to_staff").script_tool_call("escalate_to_staff")

    first = @fake.chat(system: [], messages: []).tool_calls.sole.id
    second = @fake.chat(system: [], messages: []).tool_calls.sole.id

    assert_not_equal first, second, "two tool calls in one conversation must not share an id"
    assert_equal first, FakeClaude.new.script_tool_call("escalate_to_staff").chat(system: [], messages: []).tool_calls.sole.id
  end

  test "scripts a refusal, which is a success with no usable text" do
    @fake.script_refusal

    result = @fake.chat(system: [], messages: [])

    assert result.refusal?
    assert_equal "", result.text
  end

  test "scripts a truncated answer" do
    @fake.script_truncated("Breakfast is served from")

    result = @fake.chat(system: [], messages: [])

    assert result.truncated?
    assert_not result.refusal?
  end

  test "scripts usage, including the cache read count caching assertions need" do
    @fake.script_text("Hallo", input_tokens: 4200, output_tokens: 12, cache_read_input_tokens: 3900)

    usage = @fake.chat(system: [], messages: []).usage

    assert_equal 4200, usage.input_tokens
    assert_equal 12, usage.output_tokens
    assert_equal 3900, usage.cache_read_input_tokens
    assert usage.cached?
  end

  test "scripts each failure the real client can raise" do
    @fake.script_timeout
    assert_raises(Ai::TimeoutError) { @fake.chat(system: [], messages: []) }

    @fake.script_rate_limited(retry_after: 5)
    error = assert_raises(Ai::RateLimitedError) { @fake.chat(system: [], messages: []) }
    assert_equal 5, error.retry_after

    @fake.script_server_error(status: 503)
    error = assert_raises(Ai::ApiError) { @fake.chat(system: [], messages: []) }
    assert_equal 503, error.status
    assert error.server_error?
  end

  test "an error is still recorded as a call, so a failed attempt's prompt can be inspected" do
    @fake.script_timeout

    assert_raises(Ai::TimeoutError) { @fake.chat(system: [ { text: "rules" } ], messages: []) }

    assert_equal 1, @fake.call_count
  end

  # Without this, a caller that loops over tool results one time too many gets
  # a nil back and fails somewhere unrelated, with nothing pointing at the
  # missing script line.
  test "running out of script fails loudly rather than returning nil" do
    error = assert_raises(FakeClaude::UnscriptedCall) { @fake.chat(system: [], messages: []) }

    assert_match(/ran out of scripted responses/, error.message)
  end

  test "responses come back in the order they were scripted" do
    @fake.script_text("first").script_text("second").script_text("third")

    assert_equal %w[first second third], 3.times.map { @fake.chat(system: [], messages: []).text }
    assert @fake.unscripted?
  end
end
