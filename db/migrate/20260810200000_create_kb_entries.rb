# The hotel's own published knowledge — the only thing the Slice 3 concierge
# is ever allowed to answer a hotel question from. Everything about this
# table serves that one rule.
#
# The draft/published split is the safety catch: a half-written entry ("we
# might move breakfast to 8?") must be impossible to reach a guest by
# accident, so `published` defaults to false and reaching a guest is always
# a deliberate act.
class CreateKbEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :kb_entries do |t|
      # Same cascade reasoning as rooms — see create_rooms.rb.
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }, index: false

      # facilities: 0, dining: 1, rooms: 2, policies: 3, local_area: 4,
      # transport: 5, other: 6. Defaults to `other` so an entry a hotel
      # types in a hurry still saves, rather than blocking on a taxonomy
      # decision the author may not care about.
      t.integer :category, null: false, default: 6

      t.string :title, null: false
      t.text :content, null: false

      t.boolean :published, null: false, default: false
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    # The concierge's own read: this hotel's published entries, in order.
    # Covers KbEntry.published.ordered / Hotel#published_kb_entries, which
    # runs on every AI turn.
    add_index :kb_entries, [ :hotel_id, :published, :position ]

    # Two entries called "Breakfast" in one hotel are a data-entry mistake
    # that would put contradictory text in front of the model. Scoped to the
    # hotel, so two different hotels may each have their own "Breakfast".
    add_index :kb_entries, [ :hotel_id, :title ], unique: true
  end
end
