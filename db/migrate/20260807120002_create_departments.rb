class CreateDepartments < ActiveRecord::Migration[8.0]
  def change
    create_table :departments do |t|
      # Same cascade reasoning as rooms — see create_rooms.rb.
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :departments, [ :hotel_id, :name ], unique: true
  end
end
