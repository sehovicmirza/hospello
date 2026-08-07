class CreateRequestCategories < ActiveRecord::Migration[8.0]
  def change
    create_table :request_categories do |t|
      # Same cascade reasoning as rooms — see create_rooms.rb.
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }

      # Nullable and optional, unlike hotel_id: a category can exist with no
      # department. If its department is ever removed out from under it
      # (Department#destroy itself is guarded by dependent: :restrict_with_error
      # in the normal app flow — see app/models/department.rb — this is the
      # defense-in-depth path for anything that bypasses that, e.g. direct SQL),
      # the category should survive, just lose the grouping — mirrors the
      # audit_logs on_delete: :nullify precedent for "outlives what it references."
      t.references :department, null: true, foreign_key: { on_delete: :nullify }

      t.string :key, null: false
      t.string :name, null: false
      t.string :icon
      t.boolean :active, null: false, default: true
      t.integer :position, null: false, default: 0

      # Ordered list of details the AI must gather before proposing this
      # category's request, e.g. ["date","time","people"] for a reservation.
      # Validated in the model against RequestCategory::ALLOWED_DETAIL_FIELDS.
      t.jsonb :detail_fields, null: false, default: []

      t.timestamps
    end

    add_index :request_categories, [ :hotel_id, :key ], unique: true
  end
end
