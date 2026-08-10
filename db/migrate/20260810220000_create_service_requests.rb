# The thing a guest actually asked the hotel to do, and the record a
# receptionist works from.
#
# Every column here exists to serve one product rule: **the assistant may
# gather and propose, but only a human may confirm.** A row in this table means
# a guest confirmed a request in their own words; it does not mean the hotel
# has agreed to anything. That is what `status` is for, and why it starts at
# `new` rather than at anything that sounds like a promise.
class CreateServiceRequests < ActiveRecord::Migration[8.0]
  def change
    create_table :service_requests do |t|
      # Same cascade reasoning as rooms — see create_rooms.rb.
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }, index: false

      # Where it came from. Nullify rather than cascade: a request that has
      # been accepted by a person outlives the conversation that produced it,
      # and a receptionist holding two towels needs the room number whatever
      # happened to the chat.
      t.references :conversation, foreign_key: { on_delete: :nullify }
      t.references :guest_session, foreign_key: { on_delete: :nullify }
      t.references :room, foreign_key: { on_delete: :nullify }

      t.references :request_category, null: false, foreign_key: { on_delete: :restrict }

      # Denormalized from the category on purpose. A hotel that later moves
      # "extra towels" from Housekeeping to Reception must not rewrite who
      # handled last month's requests — history is what it was.
      t.references :department, foreign_key: { on_delete: :nullify }

      t.string :summary, null: false
      t.jsonb :details, null: false, default: {}

      # The guest's own words and language, kept beside the structured
      # details. Slice 5 translates for staff; this is the original, and the
      # original is never modified (see Message#body for the same rule).
      t.text :details_original
      t.string :original_locale

      t.datetime :requested_for_at

      # new: 0, accepted: 1, in_progress: 2, completed: 3, declined: 4,
      # cancelled: 5. Starts at `new`: nothing about a guest confirming their
      # own request commits the hotel to it.
      t.integer :status, null: false, default: 0

      # normal: 0, high: 1
      t.integer :priority, null: false, default: 0

      t.references :assigned_to, foreign_key: { to_table: :users, on_delete: :nullify }

      # ai: 0, staff: 1 — where the request came from, so "how much of this is
      # the assistant actually doing" is answerable.
      t.integer :source, null: false, default: 0

      # web: 0, whatsapp: 1, matching Conversation#channel.
      t.integer :channel, null: false, default: 0

      # The duplicate guarantee, enforced by Postgres rather than by care. A
      # retried tool call, a guest tapping Confirm twice on a slow phone, and
      # a model that calls confirm twice in one turn all collapse to one row
      # — see ServiceRequest.dedupe_key_for.
      t.string :dedupe_key, null: false

      t.references :acknowledged_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :acknowledged_at
      t.datetime :completed_at

      t.timestamps
    end

    add_index :service_requests, :dedupe_key, unique: true

    # The reception board's own read: this hotel's requests, newest first,
    # filtered by status.
    add_index :service_requests, [ :hotel_id, :status, :created_at ]
  end
end
