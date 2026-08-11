class CreateWhatsappChannels < ActiveRecord::Migration[8.0]
  def change
    create_table :whatsapp_channels do |t|
      # One channel per hotel (has_one on Hotel) — the unique index added
      # below is what actually enforces that. Cascades at the DB level, not
      # a Ruby-level dependent: :destroy, for the same
      # ActsAsTenant::Errors::NoTenantSet reasoning documented on Hotel's
      # has_many :rooms/:departments/:request_categories and friends
      # (WhatsappChannel is TenantScoped too — see that model).
      # index: false — the unique index this table exists to prove
      # (below) already covers "the channel for this hotel", so a bare
      # non-unique index here would be redundant, the same reasoning
      # messages.rb documents on its own t.references :conversation.
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }, index: false

      # The hotel's displayed WhatsApp number, in E.164 (e.g.
      # "+38761234567"). Globally unique — see phone_number_id below for why
      # "globally", not merely "per hotel". This is NOT the webhook routing
      # key (phone_number_id is): it can change under number porting or
      # Meta's "Coexistence" flow while phone_number_id stays put, which is
      # exactly why routing must never key off this column.
      t.string :phone_number_e164, null: false

      # Meta's own opaque routing id for this number — distinct from
      # phone_number_e164 above. This is what actually arrives on an
      # inbound webhook (payload.entry[].changes[].value.metadata
      # .phone_number_id, Slice 6 Task 3), so it is the ONLY thing a webhook
      # can use to find which hotel a guest's message belongs to. It stays
      # constant across number porting and Coexistence even when the
      # *displayed* number above changes.
      #
      # Globally unique, deliberately NOT scoped to hotel_id: a collision
      # would route one hotel's guests into a different hotel's dashboard —
      # the worst failure available in this slice. See the unique index
      # below and test/models/whatsapp_channel_test.rb, which proves the
      # database itself — not merely the model validation — refuses a
      # collision.
      t.string :phone_number_id, null: false

      # Meta's WhatsApp Business Account id this number belongs to.
      # Informational (support/debugging, and Meta's own dashboards
      # reference it) — nothing in this slice queries by it.
      t.string :waba_id

      # meta_cloud: 0, three_sixty_dialog: 1, twilio: 2 — see
      # WhatsappChannel's enum declaration. Slice 6 ships exactly one
      # adapter (meta_cloud); the other two exist in the schema now so the
      # still-open BSP decision (see the plan's blocking questions) is an
      # adapter swap later, never a migration.
      t.integer :provider, null: false, default: 0

      # pending: 0 (registered but not yet confirmed working), active: 1
      # (sending and receiving), disabled: 2 (deliberately turned off).
      t.integer :status, null: false, default: 0

      # Meta's own free-text display-name review status (e.g. "APPROVED",
      # "PENDING", "REJECTED"), stored verbatim rather than as a Rails enum:
      # it is Meta's vocabulary, not ours, and a value this app has never
      # seen before must still be storable and displayable, not raise.
      t.string :display_name_status

      t.datetime :verified_at
      # Slice 6 Task 3 updates this on every routed inbound message; unused
      # until then. Shown on the Task 4 staff settings screen regardless —
      # a channel that has never received anything is itself worth knowing.
      t.datetime :last_inbound_at
      t.text :last_error

      t.timestamps
    end

    # One channel per hotel — the has_one side of the association. Plain
    # (not partial): every row needs this to hold, unconditionally.
    add_index :whatsapp_channels, :hotel_id, unique: true

    # The guarantee this table exists to protect: phone_number_id is how an
    # inbound webhook finds its tenant (Slice 6 Task 3), so two hotels
    # sharing one would route one hotel's guests into the other's
    # dashboard. A plain (non-partial) unique index, because unlike
    # guest_sessions.phone_e164 (WhatsApp-only, hotel-scoped — see that
    # migration) this column exists on every row and must never repeat
    # anywhere in the table, not just within one hotel.
    add_index :whatsapp_channels, :phone_number_id, unique: true

    # The displayed number is not the routing key (phone_number_id is —
    # see above), but it must still never be assigned to two hotels at
    # once: Task 4's guest-facing "Chat on WhatsApp" link is built from
    # this column, and two hotels sharing a number would send a guest's
    # very first message to the wrong one before any routing even happens.
    add_index :whatsapp_channels, :phone_number_e164, unique: true
  end
end
