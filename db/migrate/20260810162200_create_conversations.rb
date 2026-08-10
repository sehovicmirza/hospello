class CreateConversations < ActiveRecord::Migration[8.0]
  def change
    create_table :conversations do |t|
      # Cascades at the DB level, not a Ruby dependent: :destroy — same
      # ActsAsTenant::Errors::NoTenantSet reasoning documented on Hotel's
      # has_many :rooms/:departments/:request_categories/:guest_sessions
      # (Conversation is TenantScoped too).
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }
      t.references :guest_session, null: false, foreign_key: { on_delete: :cascade }

      # Denormalized from guest_session.room at creation time, purely for
      # display (Task 3's inbox shows "Room 301" without a join) — nullable
      # because a WhatsApp guest (Slice 6) may never have one.
      t.references :room, null: true, foreign_key: { on_delete: :nullify }

      # web: 0, whatsapp: 1 — mirrors GuestSession#channel; this task only
      # ever creates :web conversations.
      t.integer :channel, null: false, default: 0

      # active: 0, escalated: 1, resolved: 2, expired: 3
      t.integer :status, null: false, default: 0

      # auto: 0, paused: 1 — Slice 3's concierge reads/writes this; this
      # task never sets anything but the default.
      t.integer :ai_mode, null: false, default: 0

      # guest_requested: 0, ai_uncertain: 1, ai_unavailable: 2,
      # budget_exhausted: 3, staff_manual: 4 — nullable: only set once a
      # conversation actually escalates (Slice 3+), never by this task.
      t.integer :escalation_reason
      t.datetime :escalated_at

      # Snapshot of the guest's locale at conversation-creation time (Slice
      # 5's translation pipeline reads this) — deliberately independent of
      # guest_sessions.locale, which can change mid-stay.
      t.string :guest_locale

      t.datetime :last_guest_message_at
      t.datetime :last_message_at
      t.integer :staff_unread_count, null: false, default: 0

      t.timestamps
    end

    # The partial unique index this task exists to prove: at most one
    # *live* conversation (status active=0 or escalated=1) per guest
    # session, enforced by Postgres itself — not application care alone —
    # so two requests racing to create "the" live conversation (a guest
    # double-tapping send on a slow connection) can never both succeed.
    # The loser's insert raises ActiveRecord::RecordNotUnique, which
    # Conversation.live_for rescues and re-finds rather than propagating
    # (see that method). resolved (2) and expired (3) are deliberately
    # excluded from the WHERE clause so a guest's chat history isn't
    # capped at one row per stay — only ever one *live* row.
    add_index :conversations, :guest_session_id, unique: true,
      where: "status IN (0, 1)", name: "index_conversations_one_live_per_guest_session"
  end
end
