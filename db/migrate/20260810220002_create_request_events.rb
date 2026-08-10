# Everything that has happened to a service request: who accepted it, who it
# was assigned to, what someone wrote about it, and when each of those
# happened.
#
# Status history and internal notes share one table because they are the same
# thing to the receptionist reading them — one list, in order, of what happened
# to this request. `kind` is what decides whether the guest may be told.
class CreateRequestEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :request_events do |t|
      # Same cascade reasoning as rooms — see create_rooms.rb.
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }, index: false

      t.references :service_request, null: false, foreign_key: { on_delete: :cascade }, index: false

      # Nullable: a status change can be made by the system (an expiry, a
      # cancellation following the guest's own message) with no user behind it.
      t.references :user, foreign_key: { on_delete: :nullify }

      # status_change: 0, assignment: 1, note: 2
      t.integer :kind, null: false

      t.integer :from_status
      t.integer :to_status
      t.text :note

      t.timestamps
    end

    # The history read, in order, for one request.
    add_index :request_events, [ :service_request_id, :id ]
  end
end
