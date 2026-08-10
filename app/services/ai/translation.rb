module Ai
  # The result of one translation attempt, including the attempts that did not
  # work — which is most of the point.
  #
  # A translation that fails must cost the message nothing: the caller gets
  # the original text back, marked, and delivers that. So this object always
  # carries usable `#text`, and `#fell_back?` is how a caller knows whether
  # what it is holding is a translation or the guest's own words.
  class Translation
    # Why the original came back instead of a translation. Recorded rather
    # than collapsed into a boolean because these have very different
    # meanings for whoever reads the logs: `digit_mismatch` is the guard
    # doing its job on a model that got a number wrong, and a rate of it
    # climbing is a prompt problem; `timeout` is an infrastructure problem;
    # `refusal` on a hotel guest's message about towels is worth a look.
    REASONS = %i[timeout api_error refusal truncated empty digit_mismatch].freeze

    attr_reader :text, :locale, :usage, :reason

    def initialize(text:, locale:, usage: Result::Usage.new, reason: nil)
      @text = text
      @locale = locale
      @usage = usage
      @reason = reason
    end

    def fell_back? = reason.present?

    def translated? = !fell_back?
  end
end
