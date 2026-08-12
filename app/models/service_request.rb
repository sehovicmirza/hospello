# Something a guest asked the hotel to do.
#
# A row here means a guest confirmed a request **in their own words**. It does
# not mean the hotel has agreed to anything — that is what `status` is for, and
# why it starts at `new`. Nothing in this product may tell a guest that a
# pending request is confirmed, booked, approved or guaranteed before a person
# has acted on it, and this model is where that rule is kept honest: the only
# way a status ever changes is #transition!, which records who did it.
class ServiceRequest < ApplicationRecord
  include TenantScoped

  MAX_SUMMARY_LENGTH = 200

  enum :status, { new: 0, accepted: 1, in_progress: 2, completed: 3, declined: 4, cancelled: 5 },
       prefix: true
  enum :priority, { normal: 0, high: 1 }, prefix: true
  enum :source, { ai: 0, staff: 1 }, prefix: true
  enum :channel, { web: 0, whatsapp: 1 }, prefix: true

  # What a receptionist may still act on. A settled request stays on the board
  # only as history.
  OPEN_STATUSES = %w[new accepted in_progress].freeze

  # Which status may follow which. Written as data rather than as a chain of
  # ifs because the interesting question a reader has is "can this go from X
  # to Y", and a table answers it at a glance. `completed` and `cancelled` are
  # terminal on purpose: reopening a finished request would make the guest's
  # own status history contradict itself, and a receptionist who needs it back
  # can raise a fresh one.
  TRANSITIONS = {
    "new" => %w[accepted declined cancelled],
    "accepted" => %w[in_progress completed declined cancelled],
    "in_progress" => %w[completed cancelled],
    "completed" => [],
    "declined" => [],
    "cancelled" => []
  }.freeze

  belongs_to :conversation, optional: true
  belongs_to :guest_session, optional: true
  belongs_to :room, optional: true
  belongs_to :request_category
  belongs_to :department, optional: true
  belongs_to :assigned_to, class_name: "User", optional: true
  belongs_to :acknowledged_by, class_name: "User", optional: true

  has_many :request_events, -> { order(:id) }, dependent: :destroy

  validates :summary, presence: true, length: { maximum: MAX_SUMMARY_LENGTH }
  validates :dedupe_key, presence: true
  # The "Originals are immutable" guarantee, enforced rather than merely
  # observed — same shape and the same reasoning as
  # Message#body_is_immutable_after_creation. Nothing today calls
  # `update(details_original: ...)` (Ai::TranslateServiceRequestSummaryJob
  # only ever writes `summary`), but "nothing calls it" is not itself a
  # guarantee.
  validate :details_original_is_immutable_after_creation, on: :update

  scope :open_requests, -> { where(status: OPEN_STATUSES) }
  scope :settled, -> { where.not(status: OPEN_STATUSES) }
  # Newest first, with everything still waiting on someone above everything
  # that is not — a receptionist reads from the top and must not have to scan
  # for the request that has been sitting there for an hour. Postgres orders
  # false before true, so descending puts the open ones first. Every column is
  # table-qualified because this scope is routinely chained onto .matching,
  # which left-joins guest_sessions and rooms (see Conversation#inbox_order
  # for the PG::AmbiguousColumn this prevents).
  scope :board_order, -> {
    order(
      Arel::Nodes::Descending.new(Arel::Nodes::Grouping.new(arel_table[:status].in(statuses.values_at(*OPEN_STATUSES)))),
      arel_table[:created_at].desc,
      arel_table[:id].desc
    )
  }

  # What a receptionist has in hand: a room number, a guest's name, or a word
  # from what they asked for. Searched together rather than behind a field
  # picker, and unanchored so "301" finds "A-301" — the same reasoning as
  # Conversation.matching.
  scope :matching, ->(query) {
    query = query.to_s.strip
    next all if query.blank?

    pattern = "%#{sanitize_sql_like(query)}%"
    left_joins(:guest_session, :room).where(
      "guest_sessions.guest_name ILIKE :pattern OR rooms.number ILIKE :pattern OR service_requests.summary ILIKE :pattern",
      pattern: pattern
    )
  }

  # The duplicate guarantee. A retried tool call, a guest tapping Confirm
  # twice on a slow phone, and a model that calls confirm twice in one turn
  # all produce the same key and the unique index rejects the second — so the
  # protection is in Postgres, not in whichever caller remembered to check.
  #
  # The conversation is part of the key because two different guests asking
  # for two towels at 18:00 are two real requests; the same guest asking twice
  # in one conversation is one. Details are serialized in sorted key order so
  # that a hash built in a different order still collapses.
  def self.dedupe_key_for(conversation:, category:, details:, requested_for_at: nil)
    parts = [
      conversation&.id,
      category&.id,
      details.to_h.transform_keys(&:to_s).sort.to_json,
      requested_for_at&.utc&.iso8601
    ]

    Digest::SHA256.hexdigest(parts.join("|"))
  end

  # Rows whose guest data is still in them. Everything a purge or an erasure
  # has already been through is skipped — see the migration for why this is a
  # marker column rather than a derived "guest_session_id IS NULL".
  scope :identifiable, -> { where(anonymized_at: nil) }

  def anonymized? = anonymized_at.present?

  # Takes the guest out of a request and leaves the hotel's record of it
  # standing. Called on a relation (`hotel.service_requests.where(...)
  # .anonymize_all!`) by both Retention::PurgeExpiredGuestDataJob, on the
  # policy's clock, and Retention::GuestErasure, on a named person's request.
  # One definition of what anonymizing means, because two would disagree
  # about a column within a year and nobody would be able to say which rows
  # got which treatment.
  #
  # **What goes, and why each:**
  #
  #   summary          → the request category's own name. It cannot simply be
  #                      cleared (NOT NULL, and it is the line a receptionist
  #                      reads on the board), and it currently holds the
  #                      guest's confirmed words, translated. The category is
  #                      the hotel's own vocabulary, describes the request
  #                      without describing the person, and is already shown
  #                      beside it — so an old card reads "Extra towels"
  #                      instead of "two bath towels for Mr Halilović in 302".
  #   details          → {}. Whatever the guest supplied for the category's
  #                      own fields: times, quantities, and any name or note
  #                      they chose to type into one.
  #   details_original → NULL. Their words, verbatim, in their own language.
  #   original_locale  → NULL. Which language a person writes in is a fact
  #                      about them, and with details_original gone it
  #                      describes nothing that is still here.
  #   guest_session_id → NULL. The link to their identity.
  #   conversation_id  → NULL. The link to the transcript. Redundant with the
  #                      cascade once a conversation is purged, and not
  #                      redundant at all for an erasure that runs first.
  #   room_id          → NULL. Where a person slept on a given night, which
  #                      with the hotel's own booking system is an identity.
  #
  # **What stays, and why:** status and every timestamp (the operational
  # history this row exists for), request_category_id and department_id (what
  # kind of work it was and who does it), the staff who accepted and were
  # assigned it (staff, not guests — and "who was on shift" is the hotel's
  # own record), priority, source and channel, and `dedupe_key`, which is a
  # SHA-256 over inputs that no longer exist anywhere and is what stops two
  # rows colliding on the unique index it backs.
  #
  # update_all, so no validation and no callback runs. That is deliberate
  # twice over: this must be one statement per batch rather than one per row
  # on the largest delete this app will ever do, and
  # #details_original_is_immutable_after_creation would otherwise refuse the
  # write — correctly, since it exists to stop a *translation* overwriting an
  # original. Retention is the one thing allowed to clear it, and it has to
  # be visibly a different kind of write to get there.
  #
  # @return [Integer] how many rows were anonymized
  def self.anonymize_all!(now: Time.current)
    redaction = <<~SQL.squish
      summary = (
        SELECT name FROM request_categories
        WHERE request_categories.id = service_requests.request_category_id
      ),
      details = '{}'::jsonb,
      details_original = NULL,
      original_locale = NULL,
      guest_session_id = NULL,
      conversation_id = NULL,
      room_id = NULL,
      anonymized_at = ?,
      updated_at = ?
    SQL

    identifiable.update_all([ redaction, now, now ])
  end

  # The only way a status ever changes.
  #
  # Every change writes a RequestEvent, so "who accepted this and when" is
  # answerable without an audit trail bolted on afterwards, and the guest's
  # own status updates (Task 3) have something to fire from. An invalid
  # transition raises rather than being ignored: a silently dropped status
  # change would show a receptionist a board that disagrees with reality.
  def transition!(to:, by: nil, note: nil)
    to = to.to_s
    unless TRANSITIONS.fetch(status, []).include?(to)
      raise InvalidTransition, "a #{status} request cannot become #{to}"
    end

    from = status
    transaction do
      update!(**attributes_for_transition(to, by))
      request_events.create!(
        hotel: hotel, user: by, kind: :status_change, from_status: self.class.statuses[from],
        to_status: self.class.statuses[to], note: note
      )
    end
    notify_guest(to)
    broadcast_board
    self
  end

  class InvalidTransition < StandardError; end

  # Older than the hotel's own threshold and still waiting on someone. The
  # hotel sets the number because "late" at a 12-room guesthouse and at a
  # conference hotel are different numbers.
  def overdue?
    return false unless status_new? || status_accepted?

    created_at < hotel.overdue_after_minutes.minutes.ago
  end

  # What a reader in `locale` should see, and whether it is the original —
  # the request-summary counterpart of Message#readable_in, and the same
  # overlay rule: a receptionist reads a translation of what the guest
  # confirmed, with the guest's own words one tap away, and falls back to
  # the original whenever there is no usable translation.
  #
  # There is no separate translated_summary/translation_status column pair
  # here the way Message has: `summary` starts out equal to
  # `details_original` (see ServiceRequestDraft#build_request) and
  # Ai::TranslateServiceRequestSummaryJob overwrites it in place — but only
  # ever with a translation that already passed the digit guard inside
  # Ai::Translator, so `summary != details_original` *is* the "successfully
  # translated" signal. A translation that failed, timed out, refused, or
  # mismatched a number simply never gets here, and `summary` quietly stays
  # the original — the same "readability suffers, correctness never does"
  # trade the digit guard itself makes.
  def readable_in(locale)
    return [ summary, :original ] if details_original.blank?
    return [ summary, :translated ] if summary != details_original && locale.to_s == hotel.staff_locale.to_s

    [ details_original, :original ]
  end

  # The single answer to "does this request's summary need translating, and
  # into what" — read by both the enqueue site (ServiceRequestDraft#confirm!)
  # and the job itself (Ai::TranslateServiceRequestSummaryJob), the same way
  # Message#translation_target_locale is the one answer both a message's
  # enqueue site and its job read. Nil for the same reasons a message's
  # translation is skipped: nothing to translate, or the guest and the
  # hotel's staff already share a language — which must cost nothing at
  # all, no call, no tokens, no queued job.
  def summary_translation_target_locale
    target = hotel.staff_locale
    return nil if target.blank? || original_locale.blank? || original_locale.to_s == target.to_s
    return nil if details_original.blank?

    target
  end

  private
    # A morphing page refresh to [hotel, :requests], not a targeted replace:
    # the board's cards and its counts are different DOM shapes reacting to
    # the same event, and re-rendering from the server is what keeps every
    # count server-computed rather than nudged in the browser. Same reasoning,
    # and the same resilience layer, as the inbox.
    def broadcast_board
      Turbo::StreamsChannel.broadcast_refresh_to(hotel, :requests)
    end

    # The guest hears about every status change, in their own language, from
    # copy that lives on disk. Not a live translation: a status update is the
    # hotel keeping its word about a request the guest is waiting on, and it
    # cannot depend on a model being reachable at that moment. The staff note
    # attached to a transition is deliberately *not* passed on — it is staff
    # commentary, and Slice 5 handles anything freeform.
    #
    # Posted after the transaction, so a failed status change never announces
    # itself. Best-effort by design: a broken conversation must not roll back
    # a receptionist's completed request.
    def notify_guest(to)
      return if conversation.nil?

      body = I18n.t("requests.status.#{to}", locale: conversation.guest_locale.presence || I18n.default_locale,
                                             default: nil)
      return if body.blank?

      conversation.post_system_notice!(body: body)
    end

    def attributes_for_transition(to, by)
      attributes = { status: to }
      attributes[:acknowledged_by] = by if to == "accepted" && acknowledged_by.nil?
      attributes[:acknowledged_at] = Time.current if to == "accepted" && acknowledged_at.nil?
      attributes[:completed_at] = Time.current if to == "completed"
      attributes
    end

    def details_original_is_immutable_after_creation
      errors.add(:details_original, "cannot be changed after creation") if details_original_changed?
    end
end
