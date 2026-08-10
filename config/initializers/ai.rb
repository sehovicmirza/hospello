# Every model string and AI credential the app reads, resolved once at boot.
#
# The reason this exists rather than `ENV["AI_MODEL"]` scattered through the
# services: model ids change, and when they do the change must be one line in
# one place, not a grep across jobs, services and tests. Nothing else in the app
# may name a model directly.
#
# Nothing here is required for the app to boot. With `ANTHROPIC_API_KEY` unset
# the whole product still runs — guests chat, staff reply, the inbox works — and
# `Ai::Client#chat` raises a clear `Ai::ApiError` if something asks it to make a
# call. That is deliberate: the AI is an enhancement to guest-staff messaging,
# never a prerequisite for it (see the plan's degradation section).
Rails.application.configure do
  # The concierge model. Answers guests from the hotel's knowledge base, so it
  # is the one that has to follow grounding rules under adversarial input.
  config.x.ai.model = ENV.fetch("AI_MODEL", "claude-opus-5")

  # Translation (Slice 5) runs on every staff message in both directions and is
  # a short, mechanical task, so it gets the cheap fast model rather than the
  # concierge's. Split from AI_MODEL on purpose: translation must keep working
  # when the concierge is switched off or its budget is exhausted — it is the
  # lifeline between a guest and a receptionist who share no language.
  config.x.ai.translation_model = ENV.fetch("TRANSLATION_MODEL", "claude-haiku-4-5")

  # `.presence` so an empty-string environment variable — which is what an
  # unfilled Render field and a blank line in `.env` both produce — is treated
  # as absent rather than as a key that will fail authentication at runtime.
  config.x.ai.api_key = ENV["ANTHROPIC_API_KEY"].presence
end
