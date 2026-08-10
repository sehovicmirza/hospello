module Ai
  # A built prompt: exactly what `Ai::Client#chat` will be handed, plus the
  # three readers the tests need to say what must and must not be in it.
  #
  # It is a value object with no behaviour beyond assembly. Every decision
  # about *content* lives in Ai::PromptBuilder; this class only knows how the
  # pieces fit together and where the cache breakpoint falls.
  class Prompt
    attr_reader :system_blocks, :messages

    def initialize(system_blocks:, messages:)
      @system_blocks = system_blocks.freeze
      @messages = messages.freeze
    end

    # Everything the model is told about the hotel, as one string. Assertions
    # of the form "this appears nowhere" are written against this and
    # #full_text rather than against individual blocks, because a leak that
    # moved between blocks would otherwise slip past a per-block check.
    def system_text = system_blocks.map { |block| block[:text] }.join("\n\n")

    def full_text = [ system_text, *messages.map { |message| message[:content] } ].join("\n\n")

    # The part of the prompt the API will actually cache: everything up to and
    # including the last block flagged for caching. Two turns that produce
    # different bytes here get no cache hit at all, so this is what the
    # determinism tests compare — comparing whole prompts would compare the
    # volatile tail as well and could never be equal.
    def cached_prefix
      last_cached = system_blocks.rindex { |block| block[:cache] }
      return "" if last_cached.nil?

      system_blocks[0..last_cached].map { |block| block[:text] }.join("\n\n")
    end
  end
end
