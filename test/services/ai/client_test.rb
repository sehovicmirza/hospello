require "test_helper"

module Ai
  # These tests are about the *seam*, not about the model: what leaves this
  # process on the wire, and what shape comes back into the rest of the app.
  # Everything above this layer is tested against FakeClaude
  # (test/support/fake_claude.rb) instead.
  #
  # WebMock, deliberately not VCR. A recorded cassette keeps replaying the
  # response that matched an old prompt long after the prompt has changed, and
  # the grounding prompt changing without anyone noticing is precisely the
  # regression this slice exists to prevent.
  class ClientTest < ActiveSupport::TestCase
    MESSAGES_URL = "https://api.anthropic.com/v1/messages"

    setup do
      @client = Ai::Client.new(api_key: "sk-ant-test")
      @system = [
        { text: "You are a hotel concierge.", cache: false },
        { text: "<hotel_knowledge>Breakfast 07:00-10:30</hotel_knowledge>", cache: true }
      ]
      @messages = [ { role: "user", content: "When is breakfast?" } ]
    end

    # --- What goes out on the wire ------------------------------------------

    test "sends the configured model, the effort, and the system blocks in order" do
      body = capture_request

      chat

      assert_equal Rails.configuration.x.ai.model, body[:parsed]["model"]
      assert_equal "low", body[:parsed].dig("output_config", "effort")
      assert_equal 1024, body[:parsed]["max_tokens"]
      assert_equal [ "You are a hotel concierge.", "<hotel_knowledge>Breakfast 07:00-10:30</hotel_knowledge>" ],
                   body[:parsed]["system"].map { |block| block["text"] }
      assert_equal [ { "role" => "user", "content" => "When is breakfast?" } ], body[:parsed]["messages"]
    end

    # The cache breakpoint is the difference between a hotel's knowledge base
    # costing full price on every single guest message and costing a tenth of
    # it. It is a per-block flag, so "only the flagged block carries it" is the
    # assertion that matters, not "some block does".
    test "marks only the blocks flagged for caching with cache_control" do
      body = capture_request

      chat

      static, knowledge = body[:parsed]["system"]
      assert_nil static["cache_control"]
      assert_equal({ "type" => "ephemeral" }, knowledge["cache_control"])
    end

    test "accepts a bare string as the whole system prompt" do
      body = capture_request

      @client.chat(system: "Just this.", messages: @messages)

      assert_equal [ "Just this." ], body[:parsed]["system"].map { |block| block["text"] }
    end

    # Sent as `[]`, the API rejects the request. Guests would see the
    # degradation message and nobody would know why, so the empty case is
    # handled here rather than at each call site.
    test "omits tools entirely rather than sending an empty array" do
      body = capture_request

      chat

      assert_not body[:parsed].key?("tools")
    end

    test "sends tool definitions when there are any" do
      body = capture_request
      tool = { name: "escalate_to_staff", description: "Hand over to reception", input_schema: { type: "object" } }

      chat(tools: [ tool ])

      assert_equal [ "escalate_to_staff" ], body[:parsed]["tools"].map { |sent| sent["name"] }
    end

    test "an explicit model overrides the configured default" do
      body = capture_request

      chat(model: "claude-haiku-4-5")

      assert_equal "claude-haiku-4-5", body[:parsed]["model"]
    end

    # There is a trap in the SDK here worth a test of its own: Messages#create
    # substitutes a 600-second request timeout unless request_options is
    # non-empty, so a client-level timeout alone is silently ignored and a
    # wedged call would hold a job's concurrency slot for ten minutes. The
    # transport echoes the deadline it actually used in this header, which is
    # the only observable proof from out here that ours got through.
    test "the caller's timeout reaches the transport, not the SDK's ten-minute default" do
      headers = capture_request_headers

      chat(timeout: 25)

      assert_equal "25.0", headers[:sent]["X-Stainless-Timeout"]
    end

    test "an explicit effort overrides the default" do
      body = capture_request

      chat(effort: "high")

      assert_equal "high", body[:parsed].dig("output_config", "effort")
    end

    # --- What comes back ------------------------------------------------------

    test "returns the text blocks and nothing else" do
      # A real response from a thinking model carries the model's private
      # reasoning alongside the answer. Concatenating that into `text` would
      # put it in front of a hotel guest.
      stub_message(content: [
        { type: "thinking", thinking: "The guest is asking about breakfast.", signature: "sig" },
        { type: "text", text: "Breakfast is served 07:00-10:30." }
      ])

      result = chat

      assert_equal "Breakfast is served 07:00-10:30.", result.text
      assert_equal "end_turn", result.stop_reason
      assert_not result.refusal?
      assert_not result.tool_calls?
    end

    test "exposes tool calls with their id, name and arguments" do
      stub_message(
        stop_reason: "tool_use",
        content: [ tool_use_block("escalate_to_staff", { "reason" => "complaint", "summary" => "Broken AC" }) ]
      )

      result = chat

      assert_equal "tool_use", result.stop_reason
      call = result.tool_calls.sole
      assert_equal "toolu_01", call.id
      assert_equal "escalate_to_staff", call.name
      assert_equal "complaint", call.input["reason"]
    end

    # The gem parses response JSON with symbolize_names, so raw tool arguments
    # arrive symbol-keyed while a test author (and most validation code) reaches
    # for string keys. Normalising here is what stops `input["reason"]` from
    # silently returning nil in a server-side validator.
    test "tool arguments read the same by string and by symbol" do
      stub_message(
        stop_reason: "tool_use",
        content: [ tool_use_block("log_unanswered_question", { "question" => "Is there a pool?" }) ]
      )

      input = chat.tool_calls.sole.input

      assert_equal "Is there a pool?", input["question"]
      assert_equal "Is there a pool?", input[:question]
    end

    # A refusal is a 200 with no usable text. Any caller that reads `text`
    # without checking posts an empty message to a guest, which is why this has
    # a name of its own.
    test "a refusal is reported as one, with no text" do
      stub_message(content: [], stop_reason: "refusal")

      result = chat

      assert result.refusal?
      assert_equal "", result.text
    end

    # Thinking tokens and visible text share the max_tokens budget on current
    # models, so this is reachable with a perfectly ordinary cap and a reply
    # that is cut off mid-sentence must not be posted as if it were finished.
    test "a truncated answer is reported as one" do
      stub_message(content: [ { type: "text", text: "Breakfast is served from" } ], stop_reason: "max_tokens")

      result = chat

      assert result.truncated?
      assert_not result.refusal?
    end

    test "reports token usage including cache reads" do
      stub_message(usage: { input_tokens: 4200, output_tokens: 95, cache_read_input_tokens: 3900 })

      usage = chat.usage

      assert_equal 4200, usage.input_tokens
      assert_equal 95, usage.output_tokens
      assert_equal 3900, usage.cache_read_input_tokens
      assert usage.cached?
    end

    # The API sends null, not 0, when caching was not involved. Callers sum
    # these into ai_runs; nil arithmetic there would be an exception in a job.
    test "a null cache read count becomes zero rather than nil" do
      stub_message(usage: { input_tokens: 10, output_tokens: 5, cache_read_input_tokens: nil })

      usage = chat.usage

      assert_equal 0, usage.cache_read_input_tokens
      assert_not usage.cached?
    end

    # --- Failure mapping -------------------------------------------------------
    #
    # Nothing outside this class rescues an Anthropic:: exception, so each of
    # these is part of the seam's contract rather than an implementation detail.

    test "a timeout becomes Ai::TimeoutError" do
      stub_request(:post, MESSAGES_URL).to_timeout

      assert_raises(Ai::TimeoutError) { chat }
    end

    # `retry-after` is 1 rather than a realistic value on purpose: the SDK
    # sleeps for exactly what this header says before its retry, inside the
    # call, so a larger number here would just make the suite slower — and it
    # is the same behaviour documented on Ai::Client::MAX_RETRIES.
    test "a 429 becomes Ai::RateLimitedError carrying the server's retry advice" do
      stub_request(:post, MESSAGES_URL).to_return(
        status: 429,
        headers: { "content-type" => "application/json", "retry-after" => "1" },
        body: { type: "error", error: { type: "rate_limit_error", message: "Slow down" } }.to_json
      )

      error = assert_raises(Ai::RateLimitedError) { chat }

      assert_equal 1, error.retry_after
    end

    test "a 500 becomes an Ai::ApiError the circuit breaker will count" do
      stub_error(503)

      error = assert_raises(Ai::ApiError) { chat }

      assert_equal 503, error.status
      assert error.server_error?
    end

    # The other half of that distinction: a malformed request fails identically
    # forever, so counting it towards the breaker would take the concierge down
    # for every hotel over one bad prompt.
    test "a 400 becomes an Ai::ApiError the circuit breaker must not count" do
      stub_error(400)

      error = assert_raises(Ai::ApiError) { chat }

      assert_equal 400, error.status
      assert_not error.server_error?
    end

    test "every mapped failure is an Ai::Error, so one rescue covers them all" do
      [ Ai::TimeoutError, Ai::RateLimitedError, Ai::ApiError ].each do |klass|
        assert_operator klass, :<, Ai::Error
      end
    end

    # One retry, not the SDK's default of two: retries happen inside a single
    # #chat call, so each one multiplies the wall clock a caller waits before it
    # can fall back to a human.
    test "retries a server error exactly once" do
      stub_error(500)

      assert_raises(Ai::ApiError) { chat }

      assert_requested :post, MESSAGES_URL, times: 2
    end

    test "does not retry a client error" do
      stub_error(400)

      assert_raises(Ai::ApiError) { chat }

      assert_requested :post, MESSAGES_URL, times: 1
    end

    # --- Guards ----------------------------------------------------------------

    # The app boots and runs fully with no API key (see config/initializers/ai.rb),
    # so this has to fail as a normal, catchable AI failure rather than as a
    # NoMethodError somewhere inside the SDK.
    test "refuses to call without an API key, and sends nothing" do
      error = assert_raises(Ai::ApiError) { Ai::Client.new(api_key: nil).chat(system: @system, messages: @messages) }

      assert_match(/ANTHROPIC_API_KEY/, error.message)
      assert_not_requested :post, MESSAGES_URL
      assert_nil error.status, "a missing key is not a server error and must not open the circuit breaker"
    end

    test "an empty-string API key counts as no key at all" do
      assert_raises(Ai::ApiError) { Ai::Client.new(api_key: "").chat(system: @system, messages: @messages) }

      assert_not_requested :post, MESSAGES_URL
    end

    test "rejects an unknown effort before sending anything" do
      assert_raises(ArgumentError) { chat(effort: "extreme") }

      assert_not_requested :post, MESSAGES_URL
    end

    private

    def chat(**overrides)
      @client.chat(**{ system: @system, messages: @messages }.merge(overrides))
    end

    # Returns a hash that the stub fills in with the parsed request body once
    # the call is made — a plain container rather than an instance variable so
    # each test's assertion reads next to the call that produced it.
    def capture_request
      body = {}
      stub_request(:post, MESSAGES_URL)
        .with { |request| body[:parsed] = JSON.parse(request.body) }
        .to_return(status: 200, headers: json_headers, body: message_body.to_json)
      body
    end

    def capture_request_headers
      headers = {}
      stub_request(:post, MESSAGES_URL)
        .with { |request| headers[:sent] = request.headers }
        .to_return(status: 200, headers: json_headers, body: message_body.to_json)
      headers
    end

    def stub_message(overrides = {})
      stub_request(:post, MESSAGES_URL)
        .to_return(status: 200, headers: json_headers, body: message_body(overrides).to_json)
    end

    def stub_error(status)
      stub_request(:post, MESSAGES_URL).to_return(
        status: status,
        headers: json_headers,
        body: { type: "error", error: { type: "api_error", message: "Upstream said no" } }.to_json
      )
    end

    def json_headers = { "content-type" => "application/json" }

    def message_body(overrides = {})
      {
        id: "msg_01",
        type: "message",
        role: "assistant",
        model: "claude-opus-5",
        container: nil,
        content: [ { type: "text", text: "Breakfast is served 07:00-10:30." } ],
        stop_reason: "end_turn",
        stop_sequence: nil,
        stop_details: nil,
        usage: { input_tokens: 12, output_tokens: 8, cache_read_input_tokens: 0 }
      }.merge(overrides)
    end

    def tool_use_block(name, input, id: "toolu_01")
      { type: "tool_use", id: id, name: name, input: input, caller: { type: "direct" } }
    end
  end
end
