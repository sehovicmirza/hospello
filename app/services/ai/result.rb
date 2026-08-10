module Ai
  # Everything the rest of the app is allowed to know about a model response.
  #
  # This is a plain value object, deliberately: `Ai::Client` builds one from an
  # `Anthropic::Message` and `FakeClaude` builds one from a test's script, so a
  # test that passes against the fake is exercising the same type production
  # code receives. If this class ever grew a reference to a gem object, that
  # equivalence would quietly stop being true and every AI test in the project
  # would become worth less than it looks.
  class Result
    # A tool the model asked us to run. `input` is whatever the model emitted —
    # it is *not* trusted and it is *not* validated here. Server-side validation
    # of every argument belongs to the tool layer (Slice 3 Task 3); this class's
    # only job is to hand it over in a predictable shape.
    #
    # `input` is always a HashWithIndifferentAccess. The anthropic gem parses
    # its JSON with `symbolize_names: true`, so a raw tool input arrives with
    # symbol keys — but a test author writing a fake reaches for string keys
    # about as often, and a validator that reads `input["reason"]` against a
    # symbol-keyed hash returns nil rather than failing loudly. Normalising at
    # the seam is what stops that from ever being a question.
    ToolCall = Struct.new(:id, :name, :input, keyword_init: true) do
      def initialize(id: nil, name:, input: {})
        super(id: id, name: name.to_s, input: input.to_h.with_indifferent_access)
      end
    end

    # Token accounting, as the API reports it.
    #
    # `cache_read_input_tokens` is the number that says whether prompt caching
    # is actually working; the whole stable-then-volatile system block ordering
    # in the prompt builder exists to make it non-zero on repeat turns. The API
    # returns null rather than 0 when caching was not involved, and this
    # normalises that to 0 so callers summing tokens into `ai_runs` never have
    # to think about nil.
    class Usage
      attr_reader :input_tokens, :output_tokens, :cache_read_input_tokens

      def initialize(input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0)
        @input_tokens = input_tokens.to_i
        @output_tokens = output_tokens.to_i
        @cache_read_input_tokens = cache_read_input_tokens.to_i
      end

      def cached? = cache_read_input_tokens.positive?

      def total_tokens = input_tokens + output_tokens
    end

    attr_reader :text, :tool_calls, :stop_reason, :usage

    # `stop_reason` is normalised to a String. The gem hands back a Symbol, but
    # this value gets persisted (`ai_runs`) and compared in views and jobs, and
    # a seam that leaks the gem's choice of type is a seam that has to be
    # revisited when the gem changes its mind.
    def initialize(text: "", tool_calls: [], stop_reason: nil, usage: Usage.new)
      @text = text.to_s
      @tool_calls = tool_calls.freeze
      @stop_reason = stop_reason&.to_s
      @usage = usage
    end

    # A refusal is a *successful* HTTP response carrying no usable text, which
    # is precisely why it needs a name: code that reads `result.text` without
    # checking gets an empty string and posts it to a guest. Callers must branch
    # on this before using the reply.
    def refusal? = stop_reason == "refusal"

    def tool_calls? = tool_calls.any?

    # The model ran out of room mid-answer. On Claude 4.6+ models thinking and
    # visible text share the `max_tokens` budget, so a low cap can end a turn
    # here with `text` truncated or empty — a degradation path, not a success.
    def truncated? = stop_reason == "max_tokens"

    class << self
      # Build from an `Anthropic::Message`. The only place in the app that
      # touches the gem's response objects.
      def from_message(message)
        new(
          text: text_from(message.content),
          tool_calls: tool_calls_from(message.content),
          stop_reason: message.stop_reason,
          usage: usage_from(message.usage)
        )
      end

      private

      # Only `:text` blocks. A response can also carry `:thinking` and
      # `:redacted_thinking` blocks, and concatenating those into the reply
      # would put the model's private reasoning in front of a hotel guest.
      def text_from(content)
        content.filter_map { |block| block.text if block.type == :text }.join("\n").strip
      end

      def tool_calls_from(content)
        content.filter_map do |block|
          next unless block.type == :tool_use

          ToolCall.new(id: block.id, name: block.name, input: block.input)
        end
      end

      def usage_from(usage)
        Usage.new(
          input_tokens: usage.input_tokens,
          output_tokens: usage.output_tokens,
          cache_read_input_tokens: usage.cache_read_input_tokens
        )
      end
    end
  end
end
