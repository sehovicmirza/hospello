class CreateWebhookEvents < ActiveRecord::Migration[8.0]
  def change
    # webhook_events is deliberately NOT tenant-scoped — the one exception
    # in this entire schema. Every other table in this app carries a
    # hotel_id that acts_as_tenant enforces on every query
    # (test/tenancy/tenant_declaration_test.rb fails the suite if a new
    # hotel_id column shows up with no acts_as_tenant declaration). This
    # table can't work that way: a row here is written the instant
    # Webhooks::WhatsappController verifies a signature, which is *before*
    # anything downstream has looked at the payload — there is no tenant to
    # scope to yet, because figuring out which hotel (if any) a delivery
    # belongs to is itself the job of the code that reads this row back
    # (Slice 6 Task 3's Whatsapp::InboundRouter). Scoping a table to a
    # tenant that can't be known until after the table is written to is not
    # possible, so this one is exempt on purpose — see
    # app/models/webhook_event.rb and this table's own hotel_id column
    # below for the same note from the other two directions a future reader
    # might approach it from.
    create_table :webhook_events do |t|
      # meta_cloud: 0, three_sixty_dialog: 1, twilio: 2 — mirrors
      # whatsapp_channels.provider's own numbering (see that migration) even
      # though this Slice only ever writes meta_cloud rows: this table sits
      # one layer below any single channel's adapter, at the webhook
      # boundary itself, so its vocabulary for "which provider sent this"
      # shouldn't quietly drift from the channel table's. No default,
      # unlike whatsapp_channels.provider: every row here is written by
      # Webhooks::WhatsappController#receive, which always states the
      # provider explicitly (it has to — that's the value paired with
      # external_id below), so there is no "usually meta_cloud" case to
      # default toward the way a hand-built WhatsappChannel has.
      t.integer :provider, null: false

      # The provider's own id for whatever this delivery is *about* — a
      # message id for an inbound message, a status id for a delivery-status
      # callback — extracted by Webhooks::WhatsappController from just
      # enough of Meta's payload shape to have something stable to dedupe
      # on, and falling back to a hash of the raw body on a payload shape
      # that carries neither (see that controller's #external_id_for). This
      # is the dedupe anchor: Meta retries aggressively, and a retry of a
      # delivery this app already stored must produce zero new rows, not a
      # second one.
      t.string :external_id, null: false

      # Verbatim, exactly as Meta sent it. jsonb (not json/text) so a later
      # task can query into it if it ever needs to, and null: false because
      # every row is written from an actual webhook body — there is no
      # legitimate "received an event with no payload."
      t.jsonb :payload, null: false

      # Nullable, resolved during processing (Slice 6 Task 3): nil the
      # instant this row is written (no tenant is known yet — see the
      # create_table comment above), set once Whatsapp::InboundRouter maps
      # this delivery's phone_number_id to a WhatsappChannel/Hotel. An
      # on_delete: :nullify FK, not :cascade, deliberately: this table is an
      # operational record of what this app received and when, not
      # hotel-owned data a hotel's own deletion should take with it — and
      # nothing in this app deletes a Hotel today anyway
      # (Platform::HotelsController has no #destroy, only #suspend/#activate).
      t.references :hotel, null: true, foreign_key: { on_delete: :nullify }

      # received: 0 (stored, nothing has looked at it yet) · processed: 1
      # (routed and handled) · ignored: 2 (parsed fine but had nowhere to
      # go — an unknown phone_number_id, e.g. — set by Whatsapp::InboundRouter,
      # which never raises on this, only marks and reports) · failed: 3
      # (routed but something downstream broke; #error below carries why).
      t.integer :status, null: false, default: 0

      # Populated only for status: :failed, by whatever Slice 6 Task 3 code
      # sets that status — unused by this task, which never marks a row
      # failed itself.
      t.text :error

      t.timestamps
    end

    # The guarantee this table exists to prove, enforced by Postgres, not by
    # application care: Meta retries aggressively, so two deliveries of the
    # same (provider, external_id) pair must produce exactly one row.
    # Webhooks::WhatsappController#receive inserts through this index with
    # insert_all(..., unique_by: %i[provider external_id]) — ON CONFLICT DO
    # NOTHING — precisely so a replay is a silent no-op at the database
    # level rather than a second row a Ruby-level check might race.
    add_index :webhook_events, [ :provider, :external_id ], unique: true
  end
end
