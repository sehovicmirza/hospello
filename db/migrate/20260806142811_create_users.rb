class CreateUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users do |t|
      # Nullable on purpose: platform admins belong to no hotel.
      t.references :hotel, null: true, foreign_key: true, index: false

      t.string :email_address, null: false
      t.string :password_digest, null: false
      t.string :name, null: false
      t.integer :role, null: false, default: 0
      t.string :locale, null: false, default: "en"
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :users, :email_address, unique: true
    add_index :users, [ :hotel_id, :role ]
  end
end
