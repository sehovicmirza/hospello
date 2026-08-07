class CreateRooms < ActiveRecord::Migration[8.0]
  def change
    create_table :rooms do |t|
      # A room cannot outlive its hotel and this FK is mandatory (null: false,
      # unlike audit_logs' optional hotel_id), so on_delete is :cascade, not
      # :nullify — there is no valid "roomless hotel_id" state to fall back
      # to. Rails-level `dependent: :destroy` is deliberately NOT used on
      # Hotel's has_many :rooms: Room is tenant-scoped, so a Ruby-level
      # `hotel.rooms.destroy_all` would run outside any ActsAsTenant.with_tenant
      # block during a bare `Hotel.destroy_all`/`hotel.destroy` and raise
      # ActsAsTenant::Errors::NoTenantSet under require_tenant = true. Letting
      # Postgres cascade the delete at the DB level sidesteps that entirely.
      t.references :hotel, null: false, foreign_key: { on_delete: :cascade }
      t.string :number, null: false
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :rooms, [ :hotel_id, :number ], unique: true
    add_index :rooms, [ :hotel_id, :active ]
  end
end
