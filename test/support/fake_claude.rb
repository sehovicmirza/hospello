# A deterministic stand-in for Ai::Client.
#
# This is the contract for every AI behaviour in the project: it is written
# before the real client, and every later test of prompt construction,
# grounding, tool dispatch and degradation runs against it rather than against
# a network call.
#
# Two properties matter and are worth protecting:
#
#   1. It returns real `Ai::Result` objects, not stubs or hashes. A test that
#      passes here is exercising the same type production code receives, so a
#      change to `Ai::Result` cannot pass the fake and fail in production.
#
#   2. It records every call in `#calls`, which is what makes the *prompt*
#      testable. "This hotel's knowledge base is in the prompt and another
#      hotel's is not" is only a real test if the test can read back the system
#      blocks that were actually sent.
#
# There is deliberately no VCR anywhere in this project. A cassette recorded
# against one prompt keeps passing after the prompt changes, and a silently
# stale grounding prompt is exactly the regression this slice exists to catch.
#
#   fake = FakeClaude.new
#   fake.script_text("Breakfast is served 07:00–10:30.")
#   Ai::Concierge.new(client: fake).reply_to(conversation)
#   assert_includes fake.calls.first[:system].last[:text], "Breakfast"
class FakeClaude
  # Raised rather than returning nil, because a nil reply would be interpreted
  # by production code as "the model said nothing" and the test would fail
  # somewhere far away from the missing script line.
  class UnscriptedCall < StandardError; end

  attr_reader :calls

  def initialize
    @scripted = []
    @calls = []
  end

  # --- Scripting -----------------------------------------------------------
  #
  # Every scripter returns self, so a sequence reads as one statement:
  #   fake.script_tool_call("escalate_to_staff", reason: "…").script_text("Done.")

  # Queue an already-built Ai::Result. Use the helpers below unless a test needs
  # a shape they do not cover.
  def script(result)
    @scripted << result
    self
  end

  # Queue an exception. Accepts a class (`Ai::TimeoutError`) or an instance
  # (`Ai::ApiError.new("boom", status: 503)`) when the test cares about the
  # error's attributes.
  def script_error(error)
    @scripted << error
    self
  end

  # A plain text reply. `cache_read_input_tokens:` is how a caching assertion is
  # written without a live call.
  def script_text(text, input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0)
    script(
      Ai::Result.new(
        text: text,
        stop_reason: "end_turn",
        usage: Ai::Result::Usage.new(
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cache_read_input_tokens: cache_read_input_tokens
        )
      )
    )
  end

  # A turn that asks for one tool. `id:` defaults to a value derived from how
  # many calls have been scripted so far — deterministic on purpose, so an
  # assertion on a tool_use id does not depend on randomness.
  def script_tool_call(name, input = {}, id: nil, text: "")
    script_tool_calls([ { name: name, input: input, id: id } ], text: text)
  end

  # A turn that asks for several tools at once. The model may also emit text
  # alongside tool calls, hence `text:`.
  def script_tool_calls(tool_calls, text: "")
    calls = tool_calls.each_with_index.map do |call, index|
      Ai::Result::ToolCall.new(
        id: call[:id] || "toolu_fake_#{@scripted.size}_#{index}",
        name: call[:name],
        input: call[:input] || {}
      )
    end

    script(Ai::Result.new(text: text, tool_calls: calls, stop_reason: "tool_use"))
  end

  # The model declined. Note this is a *successful* response with no usable
  # text — the case that breaks any caller which reads `text` unconditionally.
  def script_refusal
    script(Ai::Result.new(text: "", stop_reason: "refusal"))
  end

  # The model ran out of tokens mid-answer. Whatever text it managed is present
  # but incomplete, and must not be posted to a guest as if it were finished.
  def script_truncated(text = "")
    script(Ai::Result.new(text: text, stop_reason: "max_tokens"))
  end

  def script_timeout = script_error(Ai::TimeoutError)

  def script_rate_limited(retry_after: nil)
    script_error(Ai::RateLimitedError.new("429 Too Many Requests", retry_after: retry_after))
  end

  def script_server_error(status: 500)
    script_error(Ai::ApiError.new("#{status} Server Error", status: status))
  end

  # --- The seam ------------------------------------------------------------

  def chat(**kwargs)
    @calls << kwargs

    if @scripted.empty?
      raise UnscriptedCall,
            "FakeClaude ran out of scripted responses on call #{@calls.size}. " \
            "Script one per expected model call — a caller that loops over tool " \
            "results makes more calls than you might expect."
    end

    nxt = @scripted.shift
    raise nxt if nxt.is_a?(Class) || nxt.is_a?(Exception)

    nxt
  end

  # --- Assertion helpers ---------------------------------------------------

  def call_count = @calls.size

  def last_call = @calls.last

  # The system blocks sent on a given call, in order. Block ordering is
  # load-bearing (the cache breakpoint sits after the hotel knowledge block),
  # so tests assert on the array, not on a joined string.
  def system_blocks(call_index = -1) = @calls.fetch(call_index)[:system]

  # Everything the model was told, flattened. Use for "this string appears
  # nowhere in the prompt" assertions — most importantly the cross-tenant one.
  def prompt_text(call_index = -1)
    call = @calls.fetch(call_index)
    blocks = Array(call[:system]).map { |block| block[:text] }
    blocks.concat(Array(call[:messages]).map { |message| message[:content].to_s })
    blocks.join("\n")
  end

  def unscripted? = @scripted.empty?
end
