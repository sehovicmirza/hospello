module Retention
  # What this product keeps, for how long, and why.
  #
  # **This file is the policy, not a configuration of it.** It exists so the
  # answer to "why is this row still here?" — or to the much worse question,
  # "why is this row gone?" — is a file somebody can read, rather than an
  # archaeology exercise across a purge job, a privacy notice and four locale
  # files that may or may not still agree with each other.
  #
  # Three things read these numbers and nothing else may state them:
  #
  #   1. Retention::PurgeExpiredGuestDataJob — the nightly sweep.
  #   2. Retention::GuestErasure — one named person, on request, immediately.
  #   3. The guest-facing privacy notice, in all four languages, which
  #      test/i18n/privacy_notice_retention_test.rb pins against RULES below.
  #      A notice promising 90 days beside a job that keeps 180 is worse than
  #      either alone, and it is the one kind of drift that cannot be fixed
  #      after the fact — the promise was already made to real guests.
  #
  # **Why these are durations from an instant and not the hotel's own calendar
  # day**, which every other date in this slice deliberately is: "90 days ago"
  # is the same moment in Sarajevo and in Riyadh. The analytics pages count
  # rows into a hotel's local day and would be off by one at midnight if they
  # did not; a retention window is a length of time, not a day, so a timezone
  # cannot make it wrong.
  class Policy
    # How long the guest's own conversation is kept: their name, their room,
    # their phone number, and every word either side wrote.
    #
    # The purpose we collected it for is helping this guest during this stay.
    # Once the stay is over, the only remaining reason to hold a transcript is
    # to settle something arising from it — "you said you would hold my bag",
    # "reception says I never asked for a late checkout" — and a quarter is
    # long enough for anything a guest is realistically going to raise. Past
    # that it is not an asset, it is a liability with no offsetting purpose,
    # which is exactly what storage limitation means.
    #
    # Deliberately *not* stretched to a card scheme's 120-day chargeback
    # window: this app is not the record of the stay. The hotel's PMS holds
    # the booking and the folio, and a chat transcript is not what settles a
    # disputed charge.
    GUEST_CHAT_DAYS = 90

    # How long the hotel's own operational record of a request survives after
    # the guest's identity has been stripped out of it (see
    # ServiceRequest.anonymize_all! for exactly which columns go and which
    # stay). A year, because the questions this record answers are seasonal:
    # "how many late-checkout requests did we get last August", "did response
    # times get worse after we cut the night shift". Neither is answerable
    # from a quarter, and neither needs to know who asked.
    #
    # The same window governs `ai_runs`, the per-call telemetry: once its
    # conversation is gone the row carries no guest content at all (token
    # counts, latency, model name), and a year of it is what makes a disputed
    # bill answerable.
    OPERATIONAL_DAYS = 365

    # Raw provider callbacks. `webhook_events.payload` is Meta's own JSON:
    # the guest's phone number, their WhatsApp profile name, and the verbatim
    # text of their message, in the one table in this app that is not
    # tenant-scoped. It exists to make a retry idempotent and to let somebody
    # reconstruct a delivery that went wrong. Meta retries a failed delivery
    # for hours, not weeks, and nobody has ever debugged a month-old webhook,
    # so a month is already generous for a verbatim second copy of data we
    # also hold properly somewhere else.
    WEBHOOK_EVENT_DAYS = 30

    # One record type's decision. `delete_after_days: nil` means kept for as
    # long as the hotel is a customer — which is a real decision and has to
    # be justified in `why` like any other, not a gap in the table.
    # `redact_after_days` names the earlier moment at which the personal part
    # of a row is cleared while the row itself survives.
    Rule = Data.define(:records, :delete_after_days, :redact_after_days, :anchor, :why)

    RULES = [
      Rule.new(
        records: :guest_sessions, delete_after_days: GUEST_CHAT_DAYS, redact_after_days: nil,
        anchor: "the session's own expiry — the end of the stay it represents",
        why: "The guest's identity: name, phone number, room, language. Deleting it takes " \
             "their conversations and messages with it at the database level (ON DELETE " \
             "CASCADE), which is what makes 'we deleted the chat' a guarantee Postgres " \
             "keeps rather than a list of tables somebody has to remember."
      ),
      Rule.new(
        records: :conversations, delete_after_days: GUEST_CHAT_DAYS, redact_after_days: nil,
        anchor: "the last message in the conversation",
        why: "Deleted on their own clock as well as with their guest session, because a " \
             "WhatsApp identity is renewed every time the guest writes again — so a regular " \
             "guest's session may never expire, and anchoring only on the identity would " \
             "keep their first conversation forever."
      ),
      Rule.new(
        records: :messages, delete_after_days: GUEST_CHAT_DAYS, redact_after_days: nil,
        anchor: "the conversation they belong to",
        why: "Every word either side wrote, plus its translation. The most sensitive thing " \
             "this app stores. Removed by the cascade from conversations, never separately: " \
             "a message that outlived its conversation would be unreachable and unnoticed."
      ),
      Rule.new(
        records: :service_request_drafts, delete_after_days: GUEST_CHAT_DAYS, redact_after_days: nil,
        anchor: "the conversation they belong to",
        why: "A half-finished ask, in the guest's own words. Nothing operational survives in " \
             "one — a confirmed draft has already become a ServiceRequest."
      ),
      Rule.new(
        records: :service_requests, delete_after_days: OPERATIONAL_DAYS, redact_after_days: GUEST_CHAT_DAYS,
        anchor: "when the request was made",
        why: "The hotel's operational history, not only the guest's data: what was asked " \
             "for, when it was picked up, who finished it. So the row outlives the chat — " \
             "but the guest's part of it (their words, their room, the link to them) is " \
             "cleared on the chat's own clock, so what survives is a fact about the hotel " \
             "rather than about a person. ServiceRequest.anonymize_all! lists every column."
      ),
      Rule.new(
        records: :request_events, delete_after_days: OPERATIONAL_DAYS, redact_after_days: nil,
        anchor: "the service request they belong to",
        why: "Who changed a request's status and when. Staff data about staff actions, and " \
             "meaningless without its request, so it follows one by cascade. Staff notes on " \
             "a request are never guest-visible and are not guest data."
      ),
      Rule.new(
        records: :ai_runs, delete_after_days: OPERATIONAL_DAYS, redact_after_days: nil,
        anchor: "when the call was made",
        why: "Per-call telemetry: model, tokens, latency, outcome. Carries no guest text at " \
             "all; its conversation_id is nulled by the cascade long before this, so the " \
             "row is anonymous well ahead of its own deletion. Kept a year because it is " \
             "what makes a disputed bill answerable."
      ),
      Rule.new(
        records: :ai_usage_days, delete_after_days: nil, redact_after_days: nil,
        anchor: nil,
        why: "One row per hotel per day per kind — counters, nothing else. No guest ever " \
             "appears in it, and it is the hotel's own billing record. Deleting it would " \
             "destroy the only durable evidence of what a hotel was charged for."
      ),
      Rule.new(
        records: :unanswered_questions, delete_after_days: nil, redact_after_days: GUEST_CHAT_DAYS,
        anchor: "when the gap was first recorded",
        why: "The row is the hotel's own knowledge backlog — a generalized question ('is " \
             "there parking') and how many guests have hit it. That is a fact about the " \
             "hotel's knowledge base, not about a person, so it is kept: deleting it would " \
             "reset a count that is the whole point of the screen. `question_original` is " \
             "the different thing: one guest's literal sentence, which can carry anything " \
             "they chose to put in it, so it is cleared on the chat's clock."
      ),
      Rule.new(
        records: :webhook_events, delete_after_days: WEBHOOK_EVENT_DAYS, redact_after_days: nil,
        anchor: "when the delivery arrived",
        why: "Meta's verbatim payload — the guest's number, profile name and message text. " \
             "A second copy of data already held properly elsewhere, kept only long enough " \
             "to make a retry idempotent and a bad delivery reconstructable."
      ),
      Rule.new(
        records: :audit_logs, delete_after_days: nil, redact_after_days: nil,
        anchor: nil,
        why: "Kept indefinitely, and this is the one entry where that is the *privacy* " \
             "answer rather than an exception to it: the record that an erasure happened " \
             "is the only thing that can show it happened. Retention::GuestErasure writes " \
             "one deliberately naming no guest — ids and counts, never a name or a number — " \
             "so the proof does not recreate what it is proof of destroying."
      ),
      Rule.new(
        records: :rooms, delete_after_days: nil, redact_after_days: nil,
        anchor: nil,
        why: "The hotel's own configuration, not guest data. A room number outlives every " \
             "guest who stayed in it."
      ),
      Rule.new(
        records: :departments, delete_after_days: nil, redact_after_days: nil,
        anchor: nil,
        why: "Hotel configuration — how this hotel divides its own work. No guest ever " \
             "appears in one, and every old service request points at one."
      ),
      Rule.new(
        records: :request_categories, delete_after_days: nil, redact_after_days: nil,
        anchor: nil,
        why: "Hotel configuration, and load-bearing for the anonymized requests above: a " \
             "purged request keeps its category as the only description it has left, so " \
             "deleting a category would erase what the row was about."
      ),
      Rule.new(
        records: :kb_entries, delete_after_days: nil, redact_after_days: nil,
        anchor: nil,
        why: "The hotel's own knowledge base — written by the hotel, about the hotel."
      ),
      Rule.new(
        records: :whatsapp_channels, delete_after_days: nil, redact_after_days: nil,
        anchor: nil,
        why: "Hotel configuration: the hotel's own published number and Meta routing id."
      ),
      Rule.new(
        records: :whatsapp_templates, delete_after_days: nil, redact_after_days: nil,
        anchor: nil,
        why: "Hotel configuration: what the hotel registered with Meta and what Meta said."
      ),
      Rule.new(
        records: :users, delete_after_days: nil, redact_after_days: nil,
        anchor: nil,
        why: "Staff accounts, not guests. Deactivated rather than deleted (see " \
             "Staff::UsersController) so that 'who accepted this request in March' still " \
             "has an answer. A staff member's own erasure request is an employment-law " \
             "question with a different answer, and is deliberately not automated here."
      ),
      Rule.new(
        records: :sessions, delete_after_days: nil, redact_after_days: nil,
        anchor: nil,
        why: "Staff sign-in tokens. Destroyed when a user signs out or is deactivated; " \
             "there is no scheduled sweep (see docs/plan/known-issues.md, deferred)."
      )
    ].freeze

    BY_RECORDS = RULES.index_by(&:records).freeze

    # The record types Analytics::HotelReport counts rows from directly — as
    # opposed to `ai_usage_days`, which it reads as a rollup that is never
    # deleted. Named here rather than in the report because it is a *policy*
    # fact: how far back a page can honestly look is decided by what still
    # exists, not by what a query costs.
    ANALYTICS_SOURCES = %i[conversations messages service_requests unanswered_questions].freeze

    class << self
      def rule_for(records) = BY_RECORDS.fetch(records)

      # Everything older than this has been deleted, so a page showing a
      # window wider than this is showing a decline in business that is
      # really a deletion. Analytics::HotelReport::MAX_DAYS is this number —
      # the cap follows the policy, never the other way round.
      def analytics_horizon_days
        ANALYTICS_SOURCES.filter_map { |records| rule_for(records).delete_after_days }.min
      end

      # The three cutoffs the purge job works from. Methods rather than
      # constants because `Time.current` has to be read when the job runs,
      # not when the class is loaded — a long-lived worker process would
      # otherwise purge against the moment it booted, forever.
      def guest_chat_cutoff(now = Time.current) = now - GUEST_CHAT_DAYS.days

      def operational_cutoff(now = Time.current) = now - OPERATIONAL_DAYS.days

      def webhook_event_cutoff(now = Time.current) = now - WEBHOOK_EVENT_DAYS.days
    end
  end
end
