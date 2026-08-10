# A guest's ongoing chat with a hotel. Exactly one conversation is ever
# "live" (status active or escalated) per guest session — enforced by the
# partial unique index this migration adds
# (db/migrate/*_create_conversations.rb, index_conversations_one_live_per_guest_session),
# not by application care alone, so a guest double-tapping send on a slow
# connection can never end up talking into two different conversations at
# once. See .live_for below for the race-safe lookup-or-create this backs.
class Conversation < ApplicationRecord
  include TenantScoped

  enum :channel, { web: 0, whatsapp: 1 }
  enum :status, { active: 0, escalated: 1, resolved: 2, expired: 3 }
  enum :ai_mode, { auto: 0, paused: 1 }
  enum :escalation_reason, {
    guest_requested: 0, ai_uncertain: 1, ai_unavailable: 2,
    budget_exhausted: 3, staff_manual: 4
  }

  belongs_to :guest_session
  belongs_to :room, optional: true
  has_many :messages, -> { order(:id) }, dependent: :destroy

  before_validation :assign_hotel_from_guest_session
  before_validation :assign_room_from_guest_session, on: :create
  before_validation :assign_guest_locale_from_guest_session, on: :create

  validate :guest_session_must_belong_to_the_same_hotel

  scope :live, -> { where(status: %w[active escalated]) }

  class << self
    # The guest's one live conversation, creating it if none exists yet.
    # Race-safe: the partial unique index on guest_session_id (status
    # active/escalated) is what actually prevents two live conversations
    # for the same guest session — #create_live_conversation below rescues
    # the loser of that race (ActiveRecord::RecordNotUnique) and re-finds
    # instead of letting a 500 surface for what is, from the guest's
    # perspective, a perfectly normal page load or message send.
    def live_for(guest_session)
      existing_live_conversation(guest_session) || create_live_conversation(guest_session)
    end

    # Split out from #live_for (rather than inlined) so a test can stub
    # exactly this lookup to simulate a race — see
    # test/models/conversation_test.rb — without also masking the
    # rescue's own re-find below, which calls this same method a second
    # time.
    def existing_live_conversation(guest_session)
      guest_session.conversations.live.order(id: :desc).first
    end

    private
      def create_live_conversation(guest_session)
        create!(guest_session: guest_session)
      rescue ActiveRecord::RecordNotUnique
        # The unique index guarantees a live row exists at this point —
        # this lost the race, not the guest's request.
        existing_live_conversation(guest_session) || raise
      end
  end

  # Creates the Message, touches last_guest_message_at/last_message_at,
  # increments staff_unread_count, all in one transaction, and broadcasts
  # after commit. Idempotent on client_message_id: a retried form submit
  # (a guest double-tapping send on a slow connection) returns the
  # original Message unchanged instead of creating a second one. The
  # upfront #find_by below handles the common sequential-retry case; the
  # unique index on [conversation_id, client_message_id]
  # (db/migrate/*_create_messages.rb) is what actually guarantees this
  # under a genuine concurrent race, which the rescue below covers the
  # same way .live_for's rescue does.
  def post_guest_message!(body:, client_message_id:)
    if client_message_id.present? && (existing = messages.find_by(client_message_id: client_message_id))
      return existing
    end

    message = nil
    transaction do
      message = messages.create!(
        hotel: hotel, sender_role: :guest, body: body,
        body_locale: guest_locale, client_message_id: client_message_id
      )
      touch_guest_activity!
    end
    broadcast_new_message(message)
    message
  rescue ActiveRecord::RecordNotUnique
    messages.find_by!(client_message_id: client_message_id)
  end

  # Same shape for the staff side: creates the Message and resets
  # staff_unread_count to 0 — a staff reply means whatever was unread has
  # now been seen — in one transaction, broadcasting after commit.
  def post_staff_message!(user:, body:)
    message = nil
    transaction do
      message = messages.create!(hotel: hotel, sender_role: :staff, sender_user: user, body: body)
      update!(last_message_at: Time.current, staff_unread_count: 0)
    end
    broadcast_new_message(message)
    message
  end

  private
    def touch_guest_activity!
      now = Time.current
      update!(last_guest_message_at: now, last_message_at: now, staff_unread_count: staff_unread_count + 1)
    end

    def broadcast_new_message(message)
      # This render happens outside any request — I18n.locale would
      # otherwise be whatever the last thread-local value left behind
      # (GuestLocalization's with_locale only scopes a real request; there
      # is no request here), so the sr-only sender label
      # (GuestChatHelper#guest_sender_label) would render in the wrong
      # language for a guest who picked anything but the server's default.
      I18n.with_locale(guest_locale.presence || I18n.default_locale) do
        # [conversation] — the chat itself. ConversationChannel is the
        # only subscriber a guest's browser can ever authenticate for (see
        # that channel's ownership check) — broadcasting here via
        # Turbo::StreamsChannel still reaches it, because both compute the
        # same underlying stream identifier from the same [conversation]
        # streamable (see ConversationChannel's own comment for why).
        # "append" dedupes on the rendered element's own dom_id, so this
        # is safe even though the sender's own browser is also subscribed
        # to this stream and will receive its own message back a second
        # time.
        Turbo::StreamsChannel.broadcast_append_to(
          self, target: "chat-messages", partial: "guest/messages/message", locals: { message: message }
        )
      end

      # [hotel, :inbox] — Task 3's reception inbox stream. Nothing
      # subscribes to it yet, so this is a no-op broadcast today and a
      # ready-made hook for that task.
      Turbo::StreamsChannel.broadcast_refresh_to(hotel, :inbox)
    end

    def assign_hotel_from_guest_session
      self.hotel ||= guest_session&.hotel
    end

    def assign_room_from_guest_session
      self.room ||= guest_session&.room
    end

    def assign_guest_locale_from_guest_session
      self.guest_locale ||= guest_session&.locale
    end

    # Same defense GuestSession#room_must_belong_to_the_same_hotel and
    # RequestCategory#department_must_belong_to_the_same_hotel document in
    # full: acts_as_tenant's automatic belongs_to check only covers
    # associations declared before `include TenantScoped` runs, and even
    # then only catches an *id* assignment, not an *object* assignment
    # (`conversation.guest_session = some_other_hotels_session` hands back
    # the exact object with no query at all). Re-querying GuestSession by
    # id — itself tenant-scoped — closes both gaps.
    def guest_session_must_belong_to_the_same_hotel
      return if guest_session_id.blank?

      errors.add(:guest_session, "must belong to the same hotel") unless GuestSession.where(id: guest_session_id).exists?
    end
end
