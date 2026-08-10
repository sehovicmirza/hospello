# A request the guest and the assistant are still working out.
#
# This class is where Slice 4's central promise is kept: **the assistant may
# gather and propose, but only a human may confirm.** #confirm! is the only
# path in the entire application that creates a ServiceRequest, and it refuses
# to run unless the guest has been shown a summary and said yes.
#
# Two guarantees are made by Postgres rather than by care here, because both
# are races that application-level checks lose:
#
#   * one live draft per conversation (a partial unique index), so a guest
#     cannot end up confirming one request while reading the summary of another
#   * one request per confirmed draft (the `dedupe_key` unique index), so a
#     retried tool call cannot produce a second
class ServiceRequestDraft < ApplicationRecord
  include TenantScoped

  # Long enough that a guest can put their phone down mid-sentence and pick it
  # up again; short enough that a half-finished request cannot spring to life
  # after they have left for dinner and forgotten about it.
  LIFETIME = 30.minutes

  enum :status, { gathering: 0, awaiting_confirmation: 1, confirmed: 2, discarded: 3, expired: 4 },
       prefix: true

  # The two statuses the partial unique index covers — named once so the
  # scope, the predicate and that index cannot drift apart (same shape as
  # Conversation::LIVE_STATUSES).
  LIVE_STATUSES = %w[gathering awaiting_confirmation].freeze

  belongs_to :conversation
  belongs_to :request_category, optional: true

  before_validation :assign_hotel_from_conversation
  before_validation :assign_default_expiry, on: :create

  validates :expires_at, presence: true
  validate :conversation_must_belong_to_the_same_hotel

  scope :live, -> { where(status: LIVE_STATUSES) }
  scope :past_expiry, -> { live.where(expires_at: ..Time.current) }

  def live? = LIVE_STATUSES.include?(status)

  def expired_by_time? = expires_at.present? && expires_at <= Time.current

  # What the guest is asked to confirm, and what the summary card renders —
  # the same sentence in both places on purpose, so a guest who confirms by
  # typing "yes" and a guest who taps the button are agreeing to identical
  # words. Category name first because it carries the meaning; the details
  # qualify it.
  def summary_for_guest
    qualifiers = Array(request_category&.detail_fields).filter_map do |field|
      value = details[field.to_s]
      "#{field}: #{value}" if value.present?
    end

    [ request_category&.name, qualifiers.presence&.join(", ") ].compact_blank.join(" — ")
  end

  # The conversation's one live draft, or nil. Deliberately not a
  # find_or_create: creating one is a decision the propose tool makes with a
  # category in hand, not something a reader should trigger by looking.
  def self.live_for(conversation)
    conversation.service_request_drafts.live.order(id: :desc).first
  end

  # Which details the category says are needed and this draft does not have,
  # in the category's own order. The assistant asks for `missing_fields.first`
  # — one thing at a time, because a guest on a phone will not answer three
  # questions in one message, and asking them in a stable order means a guest
  # who repeats themselves gets the same question rather than a new one.
  def missing_fields
    return [] if request_category.nil?

    Array(request_category.detail_fields).reject { |field| details[field.to_s].present? }
  end

  # True when there is nothing left to ask. This is what decides whether the
  # assistant asks another question or shows the summary card.
  def ready? = request_category.present? && missing_fields.empty?

  # **The only path in this application that creates a ServiceRequest.**
  #
  # Refuses anything but an `awaiting_confirmation` draft, which is the state
  # a draft only reaches after the guest has been shown what they are
  # confirming. A draft still `gathering` has never been summarised to anyone,
  # so confirming it would be the software deciding on the guest's behalf.
  #
  # The room, the guest session and the hotel come from the conversation — not
  # from `details`, and not from anything the model emitted. A prompt
  # injection that persuades the assistant to name another room has nowhere to
  # put it: those are not arguments to this method.
  def confirm!
    raise NotConfirmable, "a #{status} draft cannot be confirmed" unless status_awaiting_confirmation?
    raise NotConfirmable, "this draft expired at #{expires_at}" if expired_by_time?

    request = nil
    transaction do
      update!(status: :confirmed)
      request = build_request
      request.save!
    end
    request
  rescue ActiveRecord::RecordNotUnique
    # The same request already exists — the dedupe_key index caught it. This
    # is a success from the guest's side, not a failure: they asked for two
    # towels at six, and two towels at six are on the board. Telling them
    # something went wrong would be a lie that invites them to ask again, and
    # asking again is how one request becomes two.
    #
    # The transaction rolled back, so the draft is still live in the database
    # and has to be settled here.
    reload
    update!(status: :confirmed)
    ServiceRequest.find_by!(dedupe_key: dedupe_key)
  end

  # The key this draft's request would carry — read by #confirm! twice (once
  # to build, once to recover the existing row when the index says it is
  # already there), so it is computed in one place.
  def dedupe_key
    ServiceRequest.dedupe_key_for(
      conversation: conversation, category: request_category,
      details: details, requested_for_at: requested_for_at
    )
  end

  class NotConfirmable < StandardError; end

  private
    def build_request
      guest_session = conversation.guest_session

      ServiceRequest.new(
        hotel: hotel,
        conversation: conversation,
        guest_session: guest_session,
        # From the guest's own session, never from `details` — see the
        # method comment. The room a guest self-declared at sign-up is the
        # only room this request can ever be for.
        room: guest_session&.room,
        request_category: request_category,
        # Denormalized now so a later category edit does not rewrite who
        # handled this.
        department: request_category&.department,
        # The same sentence the guest agreed to. A receptionist reading a
        # different summary from the one the guest confirmed is how "that is
        # not what I asked for" conversations start.
        summary: summary_for_guest.truncate(ServiceRequest::MAX_SUMMARY_LENGTH),
        details: details,
        original_locale: conversation.guest_locale,
        requested_for_at: requested_for_at,
        channel: conversation.channel,
        source: :ai,
        dedupe_key: dedupe_key
      )
    end

    # Parsed from the details hash rather than stored in its own column: the
    # model supplies it as a string in the guest's own phrasing, and a value
    # we could not parse must not silently become "now".
    def requested_for_at
      value = details["requested_for_at"]
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def assign_hotel_from_conversation
      self.hotel ||= conversation&.hotel
    end

    def assign_default_expiry
      self.expires_at ||= LIFETIME.from_now
    end

    # Same defence Conversation#guest_session_must_belong_to_the_same_hotel
    # documents in full: re-queries by id (itself tenant-scoped) rather than
    # trusting the association reader, which would hand back a foreign object
    # with no query at all if it were assigned directly.
    def conversation_must_belong_to_the_same_hotel
      return if conversation_id.blank?

      errors.add(:conversation, "must belong to the same hotel") unless Conversation.where(id: conversation_id).exists?
    end
end
