module Ai
  # One request summary, translated for whoever has to act on it.
  #
  # The request-summary counterpart of Ai::TranslateMessageJob, and the same
  # overlay rule as messages: `details_original` is the guest's own words —
  # what they were actually shown and agreed to — and is never touched
  # again (ServiceRequest enforces that). `summary` starts out identical to
  # it (see ServiceRequestDraft#build_request), so a receptionist who opens
  # the board before this job runs simply reads the original: never wrong,
  # only not yet translated. On success this overwrites `summary` with a
  # translation into the hotel's staff language; on any failure — timeout,
  # refusal, truncation, or the digit guard catching a mangled number —
  # Ai::Translator hands back the original and this job leaves `summary`
  # exactly as it was. There is no separate translated_summary/
  # translation_status column pair to manage: `summary != details_original`
  # *is* "translated successfully", because nothing else is ever allowed to
  # make them differ.
  #
  # Enqueued once, from ServiceRequestDraft#confirm!, never from the
  # guest's own request/response cycle: a guest tapping Confirm (or typing
  # "yes" through the model) must not wait on a second AI call for a
  # translation only staff will ever read.
  class TranslateServiceRequestSummaryJob < ApplicationJob
    queue_as :ai

    # `client:` exists so tests can substitute FakeClaude; nothing in the
    # app passes it, so ActiveJob is never asked to serialize it.
    def perform(service_request, client: nil)
      # Re-checked rather than trusted from the enqueue site — a retry long
      # after a hotel changed its staff_locale, or a job that outlived a
      # test's own setup, must not translate into a language nobody asked
      # for any more.
      target = service_request.summary_translation_target_locale
      return if target.blank?

      started_at = monotonic_ms
      translation = translator(client).call(
        text: service_request.details_original, from: service_request.original_locale, to: target
      )
      record_run(service_request, translation, monotonic_ms - started_at)

      return unless translation.translated?

      service_request.update!(summary: translation.text.truncate(ServiceRequest::MAX_SUMMARY_LENGTH))
      # Not ServiceRequest#transition! — this did not change `status` — but
      # the same event the model's own broadcast_board announces: the
      # board's morphing refresh re-renders from the server either way, so
      # a card that opened untranslated updates itself once the
      # translation lands, the same way a translating message bubble does.
      Turbo::StreamsChannel.broadcast_refresh_to(service_request.hotel, :requests)
    end

    private
      def translator(client) = client ? Translator.new(client: client) : Translator.new

      # Translation shares ai_runs with the concierge and message
      # translation because "what did AI cost this hotel" has to be one
      # query, not three.
      def record_run(service_request, translation, latency_ms)
        AiRun.create!(
          hotel: service_request.hotel, conversation: service_request.conversation,
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

      # A digit mismatch is not an API error — it is this application
      # refusing a well-formed answer — but ai_runs has no value for "we
      # threw it away on purpose", and inventing one would change a table
      # three other things read. `error_class` carries the real reason; the
      # status says only that the summary was not translated.
      def status_for(reason)
        reason == :timeout ? :timeout : :api_error
      end

      def monotonic_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
  end
end
