module Ai
  # The concierge answering one guest, once.
  #
  # Everything unusual about this job is there to protect one promise: a guest
  # never hits a dead end. Their message is already saved and already in the
  # reception inbox before this job is even enqueued, so nothing here can lose
  # it — the worst case is that a person answers instead of the assistant,
  # which is the product working as designed rather than failing.
  class GenerateReplyJob < ApplicationJob
    queue_as :ai

    # Not a nicety. Without it a guest sending three messages in five seconds
    # spawns three jobs, each reading a transcript that is stale by the time
    # the model answers, and the guest gets three interleaved, contradictory
    # replies. Serialized per conversation, they instead run one after
    # another, each seeing everything that came before.
    limits_concurrency to: 1, key: ->(conversation) { "ai-conv-#{conversation.id}" }

    # Statuses that mean "the assistant could not answer, tell the guest a
    # person will" — the guest sees the same pre-translated sentence for all
    # of them, because which of our internal failures occurred is not their
    # problem.
    ESCALATION_REASONS = {
      timeout: :ai_unavailable,
      api_error: :ai_unavailable,
      refusal: :ai_unavailable,
      circuit_open: :ai_unavailable,
      budget_blocked: :budget_exhausted
    }.freeze

    # Only failures that mean "the API is not answering" count towards the
    # breaker. A refusal is the model working correctly and declining, and a
    # 4xx is our own request being wrong — opening the breaker on either would
    # take the concierge away from a whole hotel for something more calls will
    # not fix.
    BREAKER_FAILURES = %i[timeout api_error].freeze

    # `client:` and `breaker:` exist so tests can substitute FakeClaude and a
    # real cache store; nothing in the app ever passes them, so ActiveJob is
    # never asked to serialize either (see Conversation#post_guest_message!,
    # which enqueues with the conversation alone).
    def perform(conversation, client: nil, breaker: nil)
      @conversation = conversation.reload
      @hotel = conversation.hotel
      @client = client
      @breaker = breaker || CircuitBreaker.new(@hotel)

      guest_message = latest_guest_message
      return if guest_message.nil?

      # Coalescing. Every run — including the guarded ones — writes an AiRun
      # against the guest message it handled, so a job that queued behind
      # another one and finds that message already dealt with has nothing to
      # do. This is what turns a backlog into one reply per conversation
      # rather than one per message.
      return if already_handled?(guest_message)

      # Guards 1 and 2: the assistant is switched off here, by a receptionist
      # taking over or by the hotel. Both return in silence — no AiRun, no
      # message. A "someone will reply personally" notice after every guest
      # message would be noise on a conversation a human is already handling,
      # and there is no run to account for because no model was involved.
      # (This is why AiRun's status enum has no value for either case.)
      return unless conversation.auto?
      return unless hotel.ai_enabled?

      # Guards 3 and 4: the assistant is on but cannot run. These the guest
      # does need to hear about, and each writes its run.
      return degrade!(:circuit_open, guest_message) unless breaker.closed?
      return degrade!(:budget_blocked, guest_message) if over_budget?

      answer(guest_message)
    end

    private

    attr_reader :conversation, :hotel, :client, :breaker

    def answer(guest_message)
      outcome = Concierge.new(conversation: conversation, **concierge_options).reply

      unless outcome.replied?
        breaker.record_failure(failure_for(outcome)) if BREAKER_FAILURES.include?(outcome.status)
        return degrade!(outcome.status, guest_message, outcome: outcome)
      end

      breaker.record_success

      # A nil reply means a receptionist pressed Pause AI while the model was
      # thinking, and post_assistant_reply! discarded it inside its own
      # transaction. No fallback notice either — a human is already there. The
      # run is still recorded as a success, because the tokens were spent
      # whether or not the answer was used.
      conversation.post_assistant_reply!(body: outcome.text)
      record_run(status: :success, message: guest_message, outcome: outcome)
    end

    def concierge_options = client ? { client: client } : {}

    def degrade!(status, guest_message, outcome: nil)
      # Pre-translated, from disk, in the guest's own language. Never a live
      # translation call: the moment this message is needed is the moment the
      # model may be exactly what is unavailable.
      body = I18n.t("degraded.reception_will_reply", locale: guest_locale)

      conversation.post_degraded_notice!(body: body, reason: ESCALATION_REASONS.fetch(status))
      record_run(status: status, message: guest_message, outcome: outcome)
    end

    def latest_guest_message
      conversation.messages.guest_visible.where(sender_role: :guest).order(:id).last
    end

    def already_handled?(guest_message)
      AiRun.where(conversation: conversation, kind: :reply, message_id: guest_message.id).exists?
    end

    # 90%, not 100%. The remaining tenth is reserved for translation (Slice 5),
    # which is what lets a receptionist and a guest who share no language keep
    # talking — the lifeline that has to outlive the concierge.
    def over_budget? = AiRun.budget_exhausted_for?(hotel, fraction: 0.9)

    # Rebuilt rather than carried on the Outcome: the breaker only needs to
    # know timeout-or-5xx, and giving Outcome a live exception object to hold
    # would put an SDK-shaped thing back in a value object the whole seam
    # exists to keep clean.
    def failure_for(outcome)
      return TimeoutError.new if outcome.status == :timeout

      ApiError.new(outcome.error_class.to_s, status: 500)
    end

    def guest_locale = conversation.guest_locale.presence || I18n.default_locale

    def record_run(status:, message:, outcome: nil)
      AiRun.create!(
        hotel: hotel, conversation: conversation, kind: :reply, status: status,
        # The guest message this run handled — the key the coalescing check
        # above reads. Not the reply: a guarded run produces no reply at all.
        message_id: message.id,
        model: outcome&.model,
        input_tokens: outcome&.usage&.input_tokens,
        output_tokens: outcome&.usage&.output_tokens,
        cache_read_tokens: outcome&.usage&.cache_read_input_tokens,
        latency_ms: outcome&.latency_ms,
        cited_kb_entry_ids: outcome&.cited_kb_entry_ids || [],
        error_class: outcome&.error_class
      )
    end
  end
end
