class CreateMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :messages do |t|
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }
      # index: false — the explicit [conversation_id, id] index added below
      # already covers "all messages for a conversation" via its leading
      # column, so a bare single-column index here would be redundant.
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }, index: false

      # guest: 0, assistant: 1, staff: 2, system: 3 — no default: every
      # creation path (Conversation#post_guest_message!,
      # #post_staff_message!, Slice 3's assistant replies, Slice 4's system
      # notices) must say explicitly who is speaking.
      t.integer :sender_role, null: false

      # Set only for :staff messages — nullable because :guest, :assistant,
      # and :system messages never have one.
      t.references :sender_user, null: true, foreign_key: { to_table: :users, on_delete: :nullify }

      # The original, guest- or staff-typed text — never modified by
      # anything after creation (see Message#body_is_immutable_after_creation).
      # Translation (below) writes to a *different* column for exactly this
      # reason.
      t.text :body, null: false
      t.string :body_locale

      # Slice 5's translation pipeline; unused until then. Added now, not
      # as a later migration against a table already holding live guest
      # conversations.
      t.text :translated_body
      t.string :translated_locale
      # not_needed: 0, pending: 1, translated: 2, failed: 3
      t.integer :translation_status, null: false, default: 0

      # The web dedupe key: a retried form submit (a guest double-tapping
      # send on a slow connection) carries the same client_message_id, so
      # Conversation#post_guest_message! returns the original Message
      # instead of creating a second one — enforced by the unique index
      # below, not application care alone. Nullable: :staff/:system
      # messages carry none.
      t.uuid :client_message_id

      # Slice 6's WhatsApp dedupe key; nullable and unused until then.
      t.string :external_id

      # local: 0, queued: 1, sent: 2, delivered: 3, read: 4, failed: 5
      t.integer :delivery_status, null: false, default: 0
      # Slice 5's single-writer delivery claim; unused until then.
      t.datetime :delivered_at

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    # The other guarantee this task exists to prove: exactly one message
    # per send, even under a retried submit racing itself — see
    # Conversation#post_guest_message!, which rescues the
    # ActiveRecord::RecordNotUnique this raises and re-finds instead of
    # creating a duplicate.
    add_index :messages, [ :conversation_id, :client_message_id ], unique: true

    # Slice 6's WhatsApp dedupe key — partial so multiple NULLs (every
    # message that isn't from WhatsApp) never collide with each other.
    add_index :messages, :external_id, unique: true, where: "external_id IS NOT NULL"

    # The transcript's own read order and the resync endpoint's
    # "?after=<id>" filter both key off this.
    add_index :messages, [ :conversation_id, :id ]
  end
end
