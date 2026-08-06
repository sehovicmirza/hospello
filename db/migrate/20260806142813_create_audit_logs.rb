class CreateAuditLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :audit_logs do |t|
      t.references :actor_user, foreign_key: { to_table: :users }

      # Deliberately not tenant-scoped: platform-level actions may have no hotel.
      t.references :hotel, foreign_key: true, index: false

      t.string :action, null: false
      t.string :target_type
      t.bigint :target_id
      t.jsonb :metadata, null: false, default: {}

      t.datetime :created_at, null: false
    end

    add_index :audit_logs, [ :hotel_id, :created_at ]
  end
end
