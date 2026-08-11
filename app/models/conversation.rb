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
  has_many :service_request_drafts, dependent: :destroy
  has_many :service_requests

  before_validation :assign_hotel_from_guest_session
  before_validation :assign_room_from_guest_session, on: :create
  before_validation :assign_guest_locale_from_guest_session, on: :create
  before_validation :assign_channel_from_guest_session, on: :create

  validate :guest_session_must_belong_to_the_same_hotel

  # Raised when a staff reply would have to reopen a conversation the guest
  # has already moved on from. The partial unique index allows exactly one
  # live conversation per guest session, so reopening a resolved one while
  # the guest is talking in a newer one is not a database accident to be
  # rescued and retried — it means the receptionist is typing into a
  # superseded transcript the guest will never look at again, and the only
  # honest outcome is to say so and point at the live one.
  class SupersededConversation < StandardError; end

  # The statuses a guest can still be talking in — the same list the
  # partial unique index uses (status IN (0, 1)), named once so the scope,
  # the predicate, and that index cannot drift apart.
  LIVE_STATUSES = %w[active escalated].freeze

  scope :live, -> { where(status: LIVE_STATUSES) }

  def live? = LIVE_STATUSES.include?(status)

  # "Waiting on a human", written once as SQL. Deliberately *not* just
  # "has unread messages": an escalated conversation with everything read
  # is still the thing a receptionist most needs to look at.
  #
  # The scope filters by this, inbox_order sorts by it, and #needs_attention?
  # answers it for a single already-loaded row — three uses that must agree,
  # so two of them share this one definition and the third is pinned
  # against it by test/models/conversation_test.rb. An earlier version
  # spelled the same condition out a third time as an interpolated SQL
  # string inside the ORDER BY, which both duplicated the logic and read to
  # Brakeman as a possible injection.
  def self.needs_attention_predicate
    arel_table[:status].eq(statuses[:escalated]).or(
      arel_table[:status].in(LIVE_STATUSES.map { |status| statuses[status] })
        .and(arel_table[:staff_unread_count].gt(0))
    )
  end

  scope :needs_attention, -> { where(needs_attention_predicate) }
  scope :settled, -> { where(status: %w[resolved expired]) }

  # The row-level counterpart of the scope above — the inbox list marks
  # individual rows with it while the tab counts and the nav badge use the
  # scope, and the two disagreeing would mean a row flagged in one place
  # and not the other. test/models/conversation_test.rb pins them against
  # each other over the same set of conversations rather than trusting two
  # readings of the same sentence.
  def needs_attention? = escalated? || (live? && staff_unread_count.positive?)

  # Newest activity first, with everything still awaiting a human above
  # everything that isn't — a busy receptionist reads from the top and must
  # not have to scan for the urgent row. NULLS LAST because a conversation
  # created but never messaged has no last_message_at and belongs at the
  # bottom, not (as Postgres would otherwise sort a descending NULL) at the
  # very top.
  #
  # Sorting by the needs-attention predicate descending puts it first:
  # Postgres orders false before true. Every column is table-qualified —
  # arel_table does that for the predicate, and the raw fragment names its
  # table by hand — because this scope is routinely chained onto .matching,
  # which left-joins guest_sessions, and guest_sessions has a `status`
  # column of its own: an unqualified reference raised PG::AmbiguousColumn
  # the moment a receptionist typed in the search box.
  scope :inbox_order, -> {
    order(
      Arel::Nodes::Descending.new(Arel::Nodes::Grouping.new(needs_attention_predicate)),
      Arel.sql("conversations.last_message_at DESC NULLS LAST"),
      arel_table[:id].desc
    )
  }

  # Guest name and room number are what a receptionist actually has in hand
  # ("the guy in 301 who asked about towels"), so both are searched at once
  # rather than behind a field picker. ILIKE, not a full-text index: a
  # hotel's live conversation list is tens of rows, not thousands, and an
  # unanchored substring match is what makes "301" find "A-301".
  scope :matching, ->(query) {
    query = query.to_s.strip
    next all if query.blank?

    pattern = "%#{sanitize_sql_like(query)}%"
    left_joins(:guest_session, :room)
      .where("guest_sessions.guest_name ILIKE :pattern OR rooms.number ILIKE :pattern", pattern: pattern)
  }

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
  def post_guest_message!(body:, client_message_id: nil, external_id: nil)
    if (existing = existing_guest_message(client_message_id: client_message_id, external_id: external_id))
      return existing
    end

    message = nil
    transaction do
      message = messages.create!(
        hotel: hotel, sender_role: :guest, body: body,
        body_locale: guest_locale, client_message_id: client_message_id, external_id: external_id
      )
      touch_guest_activity!
    end
    broadcast_new_message(message)
    enqueue_translation(message)
    # After the broadcast, and unconditionally. The guest's message is already
    # persisted and already in the reception inbox at this point, so whether
    # an assistant also answers is a separate question with its own four
    # guards — and those live in one place, inside the job, rather than being
    # half-decided here. A job that finds the assistant switched off returns
    # in microseconds; duplicating the checks to save that would be the
    # expensive mistake, because the two copies would drift.
    Ai::GenerateReplyJob.perform_later(self)
    message
  rescue ActiveRecord::RecordNotUnique
    existing_guest_message(client_message_id: client_message_id, external_id: external_id) || raise
  end

  # Same shape for the staff side: creates the Message and resets
  # staff_unread_count to 0 — a staff reply means whatever was unread has
  # now been seen — in one transaction, broadcasting after commit.
  #
  # A reply to a resolved (or expired) conversation reopens it rather than
  # disappearing into a transcript nobody will open again: the guest's chat
  # only ever renders Conversation.live_for, so a reply left on a settled
  # conversation would be invisible to the one person it was written for.
  # The reopen can legitimately fail — see SupersededConversation — and it
  # fails inside the transaction, so the reply is rolled back with it
  # instead of landing somewhere the guest will never look.
  def post_staff_message!(user:, body:)
    message = nil
    transaction do
      # body_locale is stamped here rather than left null: without it the
      # translator has no idea what language it is reading, and "translate
      # from unknown" is how a Bosnian reply comes back as Bosnian.
      message = messages.create!(
        hotel: hotel, sender_role: :staff, sender_user: user, body: body, body_locale: hotel.staff_locale
      )
      attributes = { last_message_at: Time.current, staff_unread_count: 0 }
      attributes[:status] = :active unless live?
      update!(**attributes)
    end
    broadcast_new_message(message)
    enqueue_translation(message)
    message
  rescue ActiveRecord::RecordNotUnique
    # Only the one-live-conversation-per-guest index can raise this here,
    # and only on the reopen above: the guest has started a newer
    # conversation since this one was settled.
    raise SupersededConversation
  end

  # Staff commentary the guest must never see (Message#visibility). It
  # deliberately touches none of the inbox's own signals — not
  # last_message_at, not staff_unread_count — because a receptionist
  # jotting a note has neither answered the guest nor received anything
  # new, and letting a note reorder the inbox or clear an unread badge
  # would make both mean something other than what they say.
  def post_internal_note!(user:, body:)
    note = messages.create!(
      hotel: hotel, sender_role: :staff, sender_user: user, body: body, visibility: :internal
    )
    broadcast_new_message(note)
    note
  end

  # The Pause AI / Return to AI toggle. Nothing reads ai_mode yet — the
  # concierge arrives in Slice 3 — but the control and its audit trail
  # belong with the inbox that operates it, and building the trail now
  # means Slice 3 inherits a history that already explains itself rather
  # than one that starts mid-story.
  #
  # The system notice is internal: it is an explanation of what the *staff*
  # side did, and this slice's guest surface has never mentioned an AI at
  # all (nor should it — see the engineering rules on AI vocabulary), so a
  # guest-visible "Reception took over" would be answering a question the
  # guest was never asked.
  def pause_ai!(user:)
    set_ai_mode!(:paused, user: user, notice: "Reception took over the conversation.")
  end

  def resume_ai!(user:)
    set_ai_mode!(:auto, user: user, notice: "Reception handed the conversation back.")
  end

  # The assistant's own reply to the guest.
  #
  # It clears staff_unread_count for the same reason a staff reply does: the
  # guest has been answered, and "needs attention" is a work queue for a
  # receptionist, not an audit log of everything that was said. A concierge
  # that left every conversation flagged would recreate exactly the front-desk
  # load it exists to remove. The cases where a human really is needed are the
  # ones the assistant escalates, and an escalated conversation is in the
  # needs-attention list regardless of its unread count.
  #
  # `ai_mode` is re-checked here, inside the transaction, and NOT before it:
  # a receptionist can press Pause AI while the model is mid-flight, and the
  # only place that race can be settled is at the moment of the write. A
  # paused conversation returns nil and the caller discards the reply.
  def post_assistant_reply!(body:, locale: nil)
    message = nil
    transaction do
      lock!
      return nil unless auto?

      message = messages.create!(
        hotel: hotel, sender_role: :assistant, body: body, body_locale: locale || guest_locale
      )
      update!(last_message_at: Time.current, staff_unread_count: 0)
    end
    broadcast_new_message(message)
    message
  end

  # The guest-facing half of the degradation path: the assistant could not
  # answer, so the guest is told — in their own language, from pre-translated
  # copy — that a person will, and the conversation is escalated so that a
  # person actually does.
  #
  # staff_unread_count is deliberately left alone. Unlike an assistant reply,
  # nothing here answered the guest; the count is the receptionist's own
  # signal that something is waiting, and clearing it would hide the one case
  # that most needs a human.
  def post_degraded_notice!(body:, reason:)
    notice = nil
    transaction do
      notice = messages.create!(hotel: hotel, sender_role: :system, body: body, body_locale: guest_locale)
      attributes = { last_message_at: Time.current }
      attributes.merge!(status: :escalated, escalation_reason: reason, escalated_at: Time.current) if live?
      update!(**attributes)
    end
    broadcast_new_message(notice)
    notice
  end

  # A guest-visible system notice with nothing else attached: the receipt
  # after a guest taps Confirm on a summary card, and the "nothing has been
  # sent" after they cancel.
  #
  # Unlike #post_degraded_notice! this does not escalate and does not touch
  # the unread count. A guest confirming their own request has not asked for
  # a person — a receptionist will see the request itself on the board, which
  # is the screen built for exactly that.
  def post_system_notice!(body:)
    notice = messages.create!(hotel: hotel, sender_role: :system, body: body, body_locale: guest_locale)
    update!(last_message_at: Time.current)
    broadcast_new_message(notice)
    notice
  end

  # The assistant handing a conversation to a person — the only escalation
  # path that is not a human pressing something, and the one that has to be
  # legible afterwards. `reason` is validated by the caller (Ai::Tools)
  # against the reasons a model is allowed to choose; the summary is the
  # model's own account of why, recorded as an internal note so a
  # receptionist opening the conversation reads the handover in the
  # transcript rather than having to reconstruct it.
  #
  # A settled conversation is left alone: escalating it would flip a
  # resolved row back to live, and if the guest has since started a newer
  # conversation that violates the one-live-per-guest index. The assistant
  # only ever acts on a live conversation, so this is a guard against a
  # future caller rather than a case that happens today.
  def escalate_from_ai!(reason:, summary:)
    return false unless live?

    note = nil
    transaction do
      update!(status: :escalated, escalation_reason: reason, escalated_at: Time.current)
      note = messages.create!(
        hotel: hotel, sender_role: :system, visibility: :internal,
        body: "The assistant handed this over (#{reason.to_s.humanize.downcase}): #{summary}"
          .truncate(Message::MAX_BODY_LENGTH)
      )
    end
    broadcast_new_message(note)
    true
  end

  # Unread is a server-side count, cleared when a human actually opens the
  # conversation — never nudged from the browser, so it cannot drift away
  # from what is really in the database (see the plan's realtime section).
  def mark_read_by_staff!
    return if staff_unread_count.zero?

    update!(staff_unread_count: 0)
    Turbo::StreamsChannel.broadcast_refresh_to(hotel, :inbox)
  end

  # Assistant replies, translated for staff — lazily, the first time a
  # receptionist opens the conversation.
  #
  # The concierge already answers in the guest's own language, so the
  # staff-facing translation is only worth paying for when there is a staff
  # member actually reading it. On a hotel where the assistant handles most
  # conversations without anyone looking, translating every reply eagerly
  # would double this slice's token cost for text nobody opens.
  def request_staff_translations!
    messages.where(sender_role: :assistant, translation_status: :not_needed).find_each do |message|
      next if message.translation_target_locale.blank?

      message.update_column(:translation_status, Message.translation_statuses[:pending])
      Ai::TranslateMessageJob.perform_later(message)
    end
  end

  # The overlay landed. A refresh rather than a targeted replace, for the same
  # reason every other live update here is one: the bubble, the chip and the
  # inbox row are different DOM shapes reacting to the same event.
  def broadcast_translation(message)
    broadcast_to_guest(message) if message.guest_visible?
    Turbo::StreamsChannel.broadcast_refresh_to(hotel, :inbox)
  end

  # A delivery mark changed — sent, or failed and now needing a receptionist
  # to do something about it (Whatsapp::SendMessageJob). Staff-side only: this
  # is about whether the hotel's own words left the building, which is not a
  # thing the guest is shown. A morphing refresh for the same reason every
  # other live update here is one — it re-renders from the server rather than
  # nudging a mark client-side.
  def broadcast_delivery(_message)
    Turbo::StreamsChannel.broadcast_refresh_to(hotel, :inbox)
  end

  private
    # The two ways a guest's send can arrive twice, and the two indexes that
    # make each impossible — checked up front for the common sequential
    # retry, and again from #post_guest_message!'s rescue for a genuine
    # concurrent race.
    #
    # `client_message_id` is the web's: a uuid the browser generates, unique
    # per *conversation*, so it is looked up through this conversation's own
    # messages. `external_id` is WhatsApp's: Meta's own message id, unique
    # *globally* (see the partial index in db/migrate/*_create_messages.rb),
    # so it is looked up across the hotel rather than within one
    # conversation. That difference is not pedantry — a Meta retry arriving
    # after a receptionist resolved the conversation lands on a *new* live
    # conversation, and a lookup scoped to this one would miss it, insert,
    # and hit the global index with nothing left to recover.
    #
    # Both guards are `.present?`-gated because a nil on either column is
    # ordinary (a WhatsApp message has no client_message_id and vice versa),
    # and `find_by(column: nil)` would happily match the first row that also
    # has nothing there.
    def existing_guest_message(client_message_id:, external_id:)
      if client_message_id.present? && (existing = messages.find_by(client_message_id: client_message_id))
        return existing
      end

      Message.find_by(external_id: external_id) if external_id.present?
    end

    # Marked pending and handed to the queue, or left alone. The decision of
    # *whether* is Message#translation_target_locale's, in one place, so the
    # enqueue site cannot develop its own opinion about which direction needs
    # translating.
    def enqueue_translation(message)
      return if message.translation_target_locale.blank?

      message.update_column(:translation_status, Message.translation_statuses[:pending])
      Ai::TranslateMessageJob.perform_later(message)
    end

    # sender_user on a :system message is unusual (the column exists for
    # :staff messages) and deliberate here: "who took over" is the whole
    # point of the trail, and a name embedded in the body would be
    # unqueryable and would have to be re-typed into every future locale of
    # this string.
    def set_ai_mode!(mode, user:, notice:)
      notice_message = nil
      transaction do
        update!(ai_mode: mode)
        notice_message = messages.create!(
          hotel: hotel, sender_role: :system, sender_user: user, body: notice, visibility: :internal
        )
      end
      broadcast_new_message(notice_message)
      notice_message
    end

    def touch_guest_activity!
      now = Time.current
      update!(last_guest_message_at: now, last_message_at: now, staff_unread_count: staff_unread_count + 1)
    end

    def broadcast_new_message(message)
      if message.guest_visible?
        broadcast_to_guest(message)
        # Deliberately here, sharing broadcast_to_guest's own condition rather
        # than living in each of the six methods that post a message. "What
        # reaches the guest's browser also reaches their phone" is one rule
        # with one guard, and that guard is `guest_visible?` — the same one
        # four existing tests already protect. Six copies of it would be six
        # chances to omit the one that matters.
        deliver_to_whatsapp(message)
      end

      # [hotel, :inbox] — the reception inbox's stream (HotelInboxChannel).
      # A refresh rather than a targeted append: the inbox list and the
      # conversation detail view are different DOM shapes that both have to
      # react to the same event, and Turbo 8's morphing page refresh
      # re-renders each from the server, which is also what keeps
      # staff_unread_count server-computed rather than nudged client-side.
      # Internal notes broadcast here too — the staff side is exactly who
      # they are for.
      Turbo::StreamsChannel.broadcast_refresh_to(hotel, :inbox)
    end

    # A guest reading this conversation on WhatsApp has no browser to update:
    # the only way anything reaches them is a real outbound send. Their own
    # messages are skipped — they already have those — and everything else
    # (staff replies, the concierge's answers, the degraded notice, request
    # receipts) goes, because on this channel a message nobody sends is a
    # message nobody receives.
    def deliver_to_whatsapp(message)
      return unless whatsapp?
      return if message.guest?

      Whatsapp::SendMessageJob.perform_later(message)
    end

    # The [conversation] stream is the *guest's* browser, so nothing that
    # isn't guest-visible may ever be written to it — the third and last of
    # this app's guest-facing message reads (Guest::ChatsController#show and
    # Guest::MessagesController#index are the other two), and the only one
    # that runs with no request behind it to make the mistake obvious.
    def broadcast_to_guest(message)
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
        # .remove is a harmless no-op once the greeting is already gone
        # (same reasoning as guest/messages/create.turbo_stream.erb, which
        # this mirrors for the live-broadcast delivery path specifically).
        Turbo::StreamsChannel.broadcast_remove_to(self, target: "empty-state-greeting")
        Turbo::StreamsChannel.broadcast_append_to(
          self, target: "chat-messages", partial: "guest/messages/message", locals: { message: message }
        )
      end
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

    # Derived, never passed in. A conversation is carried on whichever
    # channel its guest reached the hotel on — there is no third answer, and
    # Conversation.live_for (the only thing that creates one) deliberately
    # takes nothing but the session. Getting this wrong is not cosmetic:
    # Slice 6 Task 4 decides whether a staff reply is sent out over WhatsApp
    # by reading exactly this column, so a WhatsApp guest on a `web`
    # conversation would be typed at and never answered.
    #
    # Assigned outright, unlike the `||=` of the three callbacks above, and
    # the difference is load-bearing rather than stylistic: `channel` has a
    # database default of `web`, so a new Conversation is never nil here and
    # `||=` would silently never fire — a WhatsApp guest would get a `web`
    # conversation and nobody would find out until a reply failed to send.
    # Overwriting a caller-supplied value is the correct behaviour anyway:
    # the guest session is the only thing that actually knows how this guest
    # reached the hotel.
    def assign_channel_from_guest_session
      self.channel = guest_session.channel if guest_session
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
