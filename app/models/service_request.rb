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

  scope :open_requests, -> { where(status: OPEN_STATUSES) }
  scope :settled, -> { where.not(status: OPEN_STATUSES) }
  scope :board_order, -> { order(created_at: :desc, id: :desc) }

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

  private
    def attributes_for_transition(to, by)
      attributes = { status: to }
      attributes[:acknowledged_by] = by if to == "accepted" && acknowledged_by.nil?
      attributes[:acknowledged_at] = Time.current if to == "accepted" && acknowledged_at.nil?
      attributes[:completed_at] = Time.current if to == "completed"
      attributes
    end
end
