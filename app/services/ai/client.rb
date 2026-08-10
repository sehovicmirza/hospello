module Ai
  # The single place in this application that talks to Anthropic.
  #
  # Everything else — the concierge, the translator, anything later — calls
  # `Ai::Client#chat` and gets an `Ai::Result` or one of the `Ai::Error`
  # subclasses. No other file references `Anthropic::` at all, which is what
  # makes the SDK replaceable and, more usefully day to day, what makes every AI
  # behaviour in the project testable by substituting `FakeClaude` (see
  # test/support/fake_claude.rb) for this object.
  #
  #   Ai::Client.new.chat(
  #     system: [ { text: RULES, cache: false }, { text: hotel_kb, cache: true } ],
  #     messages: [ { role: "user", content: "<guest_message>Wann gibt es Frühstück?</guest_message>" } ],
  #     tools: [ ... ]
  #   ) # => Ai::Result
  class Client
    # Shared by the concierge and the translator. The concierge's replies are a
    # few sentences; this is generous for that and still small enough that a
    # runaway generation cannot cost much.
    #
    # Careful, and this is the trap in the whole file: on Claude 4.6 and newer
    # models extended thinking is on by default and its tokens come out of this
    # same budget. A cap that is comfortable for the visible answer alone can
    # end a turn with `stop_reason == "max_tokens"` and little or no text — a
    # successful HTTP response carrying nothing usable. `Ai::Result#truncated?`
    # names that case; callers must treat it as a failure, not as a reply.
    DEFAULT_MAX_TOKENS = 1024

    # A grounded answer read out of a knowledge base is not a reasoning problem,
    # and a guest is watching a typing indicator while we think. Callers that
    # genuinely need more deliberation pass `effort:` explicitly.
    DEFAULT_EFFORT = "low"

    # Per attempt, in seconds. A guest waiting longer than this has already
    # decided the chat is broken; past that point the honest thing is to fall
    # back to "reception will reply personally" rather than keep them waiting.
    DEFAULT_TIMEOUT = 25

    # One retry, not the SDK's default of two. Retries happen *inside* a single
    # `#chat` call, so each one multiplies the worst-case wall clock a caller
    # sees: at two retries a 25s timeout becomes a 75s job holding a
    # concurrency slot on a conversation. One covers a transient blip; beyond
    # that the circuit breaker and the degradation path are the right answer,
    # not more waiting.
    #
    # One caveat that is not obvious from here and is worth knowing before you
    # tune this: on a 429 the SDK sleeps for whatever the response's
    # `retry-after` header asks for, *unclamped* — only its own exponential
    # backoff is capped. A server asking for a long pause therefore blocks this
    # call for that long. See docs/plan/known-issues.md.
    MAX_RETRIES = 1

    EFFORTS = %w[low medium high xhigh max].freeze

    def initialize(api_key: Rails.configuration.x.ai.api_key, model: nil)
      @api_key = api_key
      @default_model = model || Rails.configuration.x.ai.model
    end

    # @param system   [Array<Hash>] ordered system blocks, each `{ text:, cache: }`.
    #   Ordering is the caller's responsibility and is load-bearing: a block
    #   flagged `cache: true` caches everything up to and including itself, so
    #   volatile content (the current time, the guest's room) must come after
    #   the last cached block or it invalidates the prefix on every single turn.
    # @param messages [Array<Hash>] `{ role: "user"|"assistant", content: }`.
    # @param tools    [Array<Hash>] tool definitions; omitted from the request
    #   entirely when empty rather than sent as `[]`.
    # @return [Ai::Result]
    # @raise [Ai::TimeoutError, Ai::RateLimitedError, Ai::ApiError]
    def chat(
      system:,
      messages:,
      tools: [],
      model: nil,
      max_tokens: DEFAULT_MAX_TOKENS,
      effort: DEFAULT_EFFORT,
      timeout: DEFAULT_TIMEOUT
    )
      # Checked here rather than in the constructor so that building a client is
      # always safe — the app boots, and every screen that does not call a model
      # works, with no key configured at all.
      if @api_key.blank?
        raise ApiError.new(
          "ANTHROPIC_API_KEY is not set — the AI concierge cannot run without it. " \
          "See .env.example (local) or render.yaml (production)."
        )
      end

      params = {
        model: model.presence || @default_model,
        max_tokens: max_tokens,
        system_: system_blocks(system),
        messages: messages,
        output_config: { effort: normalized_effort(effort) },
        request_options: { timeout: timeout, max_retries: MAX_RETRIES }
      }
      params[:tools] = tools if tools.present?

      Result.from_message(anthropic.messages.create(**params))
    rescue Anthropic::Errors::APITimeoutError => e
      raise TimeoutError, e.message
    rescue Anthropic::Errors::RateLimitError => e
      raise RateLimitedError.new(e.message, retry_after: retry_after_from(e))
    rescue Anthropic::Errors::APIStatusError => e
      raise ApiError.new(e.message, status: e.status)
    rescue Anthropic::Errors::APIError => e
      # Connection failures and anything else the SDK raises that never got as
      # far as an HTTP status.
      raise ApiError, e.message
    end

    private

    def anthropic
      # `timeout:` and `max_retries:` are passed per request instead of here, so
      # one client object serves calls with different deadlines. Note the SDK's
      # own quirk: `Messages#create` substitutes a 600-second request timeout
      # unless `request_options` is non-empty, which is why `#chat` always
      # passes it explicitly rather than relying on a client-level default.
      @anthropic ||= Anthropic::Client.new(api_key: @api_key)
    end

    # `{ text:, cache: }` → the API's text block shape. A block flagged for
    # caching gets `cache_control`, which marks a breakpoint: the prompt prefix
    # up to and including that block is cached and read back at a fraction of
    # the input price on the next turn. A hotel's knowledge base is the block
    # that matters — it is the same thousands of tokens on every message that
    # hotel's guests ever send.
    def system_blocks(system)
      blocks = system.is_a?(String) ? [ { text: system } ] : Array(system)

      blocks.map do |block|
        text_block = { type: "text", text: block[:text].to_s }
        text_block[:cache_control] = { type: "ephemeral" } if block[:cache]
        text_block
      end
    end

    def normalized_effort(effort)
      effort = effort.to_s
      unless EFFORTS.include?(effort)
        raise ArgumentError, "Unknown effort #{effort.inspect} — expected one of #{EFFORTS.join(', ')}"
      end

      effort.to_sym
    end

    # The API sends `retry-after` in seconds on a 429 when it has advice to
    # give. Absent on some responses, hence the nil-safety — a caller must read
    # nil as "no advice", never as "retry now".
    def retry_after_from(error)
      headers = error.headers
      return nil if headers.blank?

      # Case-insensitively, because HTTP header names are case-insensitive and
      # nothing in the SDK's contract promises which casing survives the
      # transport.
      _, value = headers.find { |name, _| name.to_s.casecmp?("retry-after") }
      value.presence&.to_i
    end
  end
end
