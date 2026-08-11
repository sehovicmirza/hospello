# A single message in a Conversation — from the guest, from staff, from
# the (future, Slice 3) AI assistant, or a system notice. #body is the
# original text and is never modified by anything after creation (see
# #body_is_immutable_after_creation below); translation (Slice 5) writes to
# the separate translated_body column for exactly this reason.
class Message < ApplicationRecord
  include TenantScoped

  MAX_BODY_LENGTH = 1000

  # prefix: true on the two status enums — both declare a "failed" value
  # (translation_status and delivery_status), which would otherwise collide
  # on the same generated `failed?` instance method.
  enum :sender_role, { guest: 0, assistant: 1, staff: 2, system: 3 }
  # `translating` is the claim: a message moves pending → translating in one
  # atomic statement (see #claim_translation!), so exactly one job ever spends
  # tokens on it however many times it is enqueued or retried. `failed` is a
  # settled outcome, not an error — it means the reader gets the original,
  # which is the whole design (see Ai::Translator).
  enum :translation_status, {
    not_needed: 0, pending: 1, translated: 2, failed: 3, translating: 4
  }, prefix: true
  enum :delivery_status, { local: 0, queued: 1, sent: 2, delivered: 3, read: 4, failed: 5 }, prefix: true

  # Whether the guest may ever see this message. Internal notes (the
  # reception inbox's staff commentary) share this table with guest-visible
  # replies so the conversation detail view reads as one chronological
  # story — see db/migrate/*_add_visibility_to_messages.rb. Every
  # guest-facing read goes through the .guest_visible scope below; nothing
  # on the guest surface may ever read `messages` unfiltered.
  enum :visibility, { guest_visible: 0, internal: 1 }

  belongs_to :conversation
  belongs_to :sender_user, class_name: "User", optional: true

  before_validation :assign_hotel_from_conversation

  validates :body, presence: true, length: {
    maximum: MAX_BODY_LENGTH, message: "is too long (maximum is #{MAX_BODY_LENGTH} characters)"
  }
  validates :sender_role, presence: true
  validate :conversation_must_belong_to_the_same_hotel
  validate :sender_user_must_belong_to_the_same_hotel
  validate :internal_is_only_for_staff_authored_messages
  validate :body_is_immutable_after_creation, on: :update
  validate :visibility_is_immutable_after_creation, on: :update

  scope :chronological, -> { order(:id) }
  scope :after_id, ->(id) { id.present? ? where(arel_table[:id].gt(id)) : all }

  # Translations in flight that have taken longer than they are worth. A
  # message stuck in `translating` because its job died is a bubble that shows
  # "translating…" forever, which is worse than showing the original.
  scope :translation_overdue, ->(budget) {
    where(translation_status: [ :pending, :translating ]).where(updated_at: ..budget.ago)
  }

  # Who this message needs translating for, and into what — nil when nobody
  # does. This is the single answer to "which direction", so the enqueue site,
  # the job and the watchdog cannot each have their own opinion.
  #
  # A guest message is read by staff, so it goes into the hotel's staff
  # language; a staff reply is read by the guest, so it goes into theirs. An
  # assistant reply is already in the guest's language and only ever needs the
  # staff-facing direction — which is why nothing enqueues it on creation:
  # see Conversation#request_staff_translations!, which does it lazily when a
  # receptionist actually opens the conversation. Translating every AI reply
  # eagerly would double this slice's token cost for text nobody reads.
  #
  # System notices are absent on purpose: they are already pre-translated on
  # disk (config/locales/degraded.*, requests.*), and asking a model to
  # translate a string we wrote in four languages ourselves would be a round
  # trip that can only make it worse.
  def translation_target_locale
    source = body_locale.presence
    target = {
      "guest" => hotel.staff_locale,
      "staff" => conversation.guest_locale,
      "assistant" => hotel.staff_locale
    }[sender_role]

    return nil if target.blank? || source.blank? || source == target

    target
  end

  # The atomic claim. Returns true for exactly one caller; everyone else gets
  # false and does nothing. Same shape as the dedupe_key index and the
  # one-live-draft index: the guarantee is a database statement, not a check
  # somebody remembered to run.
  def claim_translation!
    claimed = self.class.where(id: id, translation_status: self.class.translation_statuses[:pending])
                        .update_all(translation_status: self.class.translation_statuses[:translating],
                                    updated_at: Time.current)
    reload if claimed == 1
    claimed == 1
  end

  # The overlay. `body` is never touched — the original is what was said, and
  # #body_is_immutable_after_creation enforces that regardless of what any
  # caller intends.
  def apply_translation!(translation)
    update!(
      translated_body: translation.text,
      translated_locale: translation.locale,
      translation_status: translation.translated? ? :translated : :failed
    )
  end

  # The outbound counterpart of #claim_translation!, and it exists for a
  # sharper reason: a WhatsApp message that goes out twice cannot be recalled,
  # and the guest simply sees the hotel say the same thing twice. `local` is
  # every message's starting state (on the web it is also its final one —
  # nothing is ever *sent* there), so this moves local → queued in one atomic
  # statement and exactly one caller gets past it, however many times the job
  # is enqueued or retried.
  def claim_delivery!
    claimed = self.class.where(id: id, delivery_status: self.class.delivery_statuses[:local])
                        .update_all(delivery_status: self.class.delivery_statuses[:queued],
                                    updated_at: Time.current)
    reload if claimed == 1
    claimed == 1
  end

  # A translation that has been asked for and has not settled yet. Only the
  # WhatsApp send path waits on this: on the web the translation lands as an
  # overlay in a page that is already showing the message, so there is nothing
  # to wait for.
  def translation_in_flight? = translation_status_pending? || translation_status_translating?

  # How far along the delivery ladder each status is. Out-of-order callbacks
  # are ordinary on WhatsApp — a `read` really can arrive before its
  # `delivered` — so arrival order is not trustworthy and a callback is
  # applied only when it moves the message *forward*.
  #
  # `failed` sits at the top deliberately: it is the one outcome a
  # receptionist has to act on, and once a send has failed no later success
  # callback for that same id can be true. The practical effect is "once
  # failed, stays failed", which is the conservative direction — the
  # alternative would let a stray late callback quietly hide a message that
  # never arrived.
  DELIVERY_PROGRESS = {
    "local" => 0, "queued" => 1, "sent" => 2, "delivered" => 3, "read" => 4, "failed" => 5
  }.freeze

  # @param status [Whatsapp::DeliveryStatus]
  # @return [Boolean] whether anything actually changed.
  def apply_delivery_status!(status)
    reached = DELIVERY_PROGRESS[status.status.to_s]
    # A status vocabulary this app does not model. Dropped rather than
    # guessed at: writing an unknown value into an enum column raises, and
    # mapping it to the nearest neighbour would invent a fact about a
    # message somebody is reading.
    return false if reached.nil?
    return false if reached <= DELIVERY_PROGRESS.fetch(delivery_status, 0)

    attributes = { delivery_status: status.status }
    # A read message was self-evidently delivered, whether or not that
    # callback ever arrived — so `read` fills this in too rather than leaving
    # a hole that reads as "never delivered".
    attributes[:delivered_at] = status.timestamp || Time.current if
      delivered_at.nil? && %w[delivered read].include?(status.status.to_s)

    # update_columns, like #claim_translation!'s own write: this is delivery
    # bookkeeping arriving several times per sent message, and re-running the
    # whole record's validations — including the immutability guards, which
    # exist to police *content* — to move a status one notch would be
    # spending a lot to protect nothing.
    update_columns(**attributes, updated_at: Time.current)
    true
  end

  # What a reader in `locale` should see, and whether it is the original.
  # Falls back to the original whenever there is no usable translation, which
  # covers every failure mode at once.
  def readable_in(locale)
    return [ body, :original ] if translated_body.blank? || translated_locale.to_s != locale.to_s

    [ translated_body, :translated ]
  end

  private
    def assign_hotel_from_conversation
      self.hotel ||= conversation&.hotel
    end

    # Same defense as Conversation#guest_session_must_belong_to_the_same_hotel
    # — re-queries by id (itself tenant-scoped) rather than trusting the
    # `conversation` association reader, which would hand back a foreign
    # object with no query at all if it were assigned directly.
    def conversation_must_belong_to_the_same_hotel
      return if conversation_id.blank?

      errors.add(:conversation, "must belong to the same hotel") unless Conversation.where(id: conversation_id).exists?
    end

    # User is exempt from acts_as_tenant (platform admins belong to no
    # hotel — see TenantDeclarationTest::EXEMPT), so this reads through
    # User.for_hotel rather than a bare `User.where(id: ...)`, which would
    # not raise or filter and so would happily confirm a staff id from a
    # different hotel.
    def sender_user_must_belong_to_the_same_hotel
      return if sender_user_id.blank?

      errors.add(:sender_user, "must belong to the same hotel") unless User.for_hotel(hotel).exists?(id: sender_user_id)
    end

    # The "Originals are immutable" guarantee, enforced rather than merely
    # observed: nothing today calls Message#update(body: ...), but "nothing
    # calls it" is not itself a guarantee — this makes an actual attempt to
    # change body fail validation, on every update, forever.
    def body_is_immutable_after_creation
      errors.add(:body, "cannot be changed after creation") if body_changed?
    end

    # An internal note that could later be flipped guest-visible is a leak
    # with a delay on it; the reverse would retract something the guest has
    # already read. Neither is a thing this product should be able to do, so
    # visibility is settled at creation and frozen — same shape, and the
    # same reasoning, as body's immutability above.
    def visibility_is_immutable_after_creation
      errors.add(:visibility, "cannot be changed after creation") if visibility_changed?
    end

    # Only the two staff-authored roles may ever be internal: a note a
    # receptionist types, and a system notice about what staff did
    # (Conversation#pause_ai!/#resume_ai!, whose transcript entries explain
    # the staff side's own history). A *guest's* message marked internal
    # would mean a request parameter had reached this attribute — the guest
    # would be typing into a transcript they cannot read back, a stranger
    # failure than a refused write — and an assistant reply (Slice 3) is by
    # definition an answer to the guest.
    INTERNAL_CAPABLE_ROLES = %w[staff system].freeze

    def internal_is_only_for_staff_authored_messages
      return unless internal?
      return if INTERNAL_CAPABLE_ROLES.include?(sender_role)

      errors.add(:visibility, "is only available on staff messages and system notices")
    end
end
