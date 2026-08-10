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
  enum :translation_status, { not_needed: 0, pending: 1, translated: 2, failed: 3 }, prefix: true
  enum :delivery_status, { local: 0, queued: 1, sent: 2, delivered: 3, read: 4, failed: 5 }, prefix: true

  belongs_to :conversation
  belongs_to :sender_user, class_name: "User", optional: true

  before_validation :assign_hotel_from_conversation

  validates :body, presence: true, length: {
    maximum: MAX_BODY_LENGTH, message: "is too long (maximum is #{MAX_BODY_LENGTH} characters)"
  }
  validates :sender_role, presence: true
  validate :conversation_must_belong_to_the_same_hotel
  validate :sender_user_must_belong_to_the_same_hotel
  validate :body_is_immutable_after_creation, on: :update

  scope :chronological, -> { order(:id) }
  scope :after_id, ->(id) { id.present? ? where(arel_table[:id].gt(id)) : all }

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
end
