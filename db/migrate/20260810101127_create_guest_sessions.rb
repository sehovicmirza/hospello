class CreateGuestSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :guest_sessions do |t|
      # A guest session cannot outlive its hotel and this FK is mandatory —
      # cascade at the DB level, not a Ruby-level dependent: :destroy, for the
      # same ActsAsTenant::Errors::NoTenantSet reason documented on Hotel's
      # has_many :rooms/:departments/:request_categories (GuestSession is
      # TenantScoped too).
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }

      # Nullable: WhatsApp guests (Slice 6) start roomless and may never set
      # one; web guests (this task) always have one from the entry form.
      # :nullify, not :cascade — deleting a room must not destroy an
      # otherwise-live guest session.
      t.references :room, null: true, foreign_key: { on_delete: :nullify }

      # web: 0, whatsapp: 1 — see GuestSession's enum declaration.
      t.integer :channel, null: false, default: 0

      # SHA-256 digest of the signed cookie token (GuestSession.digest /
      # .authenticate_by_token) — the raw token itself is never stored, so a
      # database leak does not hand over live guest sessions. Nullable:
      # WhatsApp sessions (Slice 6) carry no cookie and so no token at all.
      t.string :token_digest

      # Optional for web guests (acceptance scenario 3 — no phone given); the
      # identity key for WhatsApp guests, where the partial unique index
      # below is what actually enforces "one WhatsApp session per hotel per
      # phone number."
      t.string :phone_e164

      t.string :guest_name, null: false
      t.string :locale, null: false, default: "en"

      # unverified: 0, staff_verified: 1. Every session is created unverified
      # — see GuestSession's `after_initialize`/attr-protection for why no
      # code path, staff-created or mass-assigned, can produce anything else.
      t.integer :identity_status, null: false, default: 0

      t.datetime :privacy_accepted_at, null: false

      # active: 0, blocked: 1
      t.integer :status, null: false, default: 0

      t.datetime :last_seen_at
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :guest_sessions, :token_digest
    add_index :guest_sessions, [ :hotel_id, :last_seen_at ]

    # One live WhatsApp session per hotel per phone number — scoped to
    # channel = 1 (whatsapp) only, so two web sessions (phone_e164 blank, or
    # coincidentally identical) never collide with this constraint.
    add_index :guest_sessions, [ :hotel_id, :phone_e164 ], unique: true, where: "channel = 1"
  end
end
