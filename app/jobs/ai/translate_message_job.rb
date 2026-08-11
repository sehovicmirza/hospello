module Ai
  # One message, translated for whoever has to read it.
  #
  # It never blocks the message. By the time this runs, the message is already
  # persisted and already on both surfaces — the translation arrives after, as
  # an overlay, and the reader's page updates itself. That is a deliberate
  # choice for the web channel, where nothing is *sent* and both surfaces
  # render live from the database: holding a guest's message out of the
  # reception inbox for up to fifteen seconds so the receptionist's first
  # sight of it is translated would trade a real failure (an inbox showing
  # nothing after a guest hit send) for a cosmetic one (a second of the
  # guest's own words). See docs/plan/known-issues.md for the full argument
  # and for the WhatsApp case, where a message really is sent once and the
  # answer is different.
  class TranslateMessageJob < ApplicationJob
    queue_as :ai

    # `client:` exists so tests can substitute FakeClaude; nothing in the app
    # passes it, so ActiveJob is never asked to serialize it.
    def perform(message, client: nil)
      target = message.translation_target_locale
      return if target.blank?
      # The atomic claim. Whatever else is running — a retry, a duplicate
      # enqueue, the watchdog — exactly one caller gets past this line, so a
      # message is never paid for twice.
      return unless message.claim_translation!

      started_at = monotonic_ms
      translation = translator(client).call(text: message.body, from: message.body_locale, to: target)

      message.apply_translation!(translation)
      record_run(message, translation, monotonic_ms - started_at)
      # The reader's page updates itself; nothing about the message changed
      # except that it can now be read.
      message.conversation.broadcast_translation(message)
    end

    private
      def translator(client) = client ? Translator.new(client: client) : Translator.new

      # Translation shares ai_runs with the concierge because "what did AI
      # cost this hotel" has to be one query, not two — and because a hotel
      # whose translation is quietly failing all day should be visible in the
      # same place its concierge is.
      def record_run(message, translation, latency_ms)
        AiRun.create!(
          hotel: message.hotel, conversation: message.conversation, message: message,
          kind: :translation,
          status: translation.translated? ? :success : status_for(translation.reason),
          model: Rails.configuration.x.ai.translation_model,
          input_tokens: translation.usage.input_tokens,
          output_tokens: translation.usage.output_tokens,
          cache_read_tokens: translation.usage.cache_read_input_tokens,
          latency_ms: latency_ms,
          error_class: translation.reason&.to_s
        )
      end

      # A digit mismatch is not an API error — it is this application refusing
      # a well-formed answer — but ai_runs has no value for "we threw it away
      # on purpose", and inventing one would change a table four other things
      # read. `error_class` carries the real reason; the status says only that
      # the guest did not get a translation.
      def status_for(reason)
        reason == :timeout ? :timeout : :api_error
      end

      def monotonic_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
  end
end
