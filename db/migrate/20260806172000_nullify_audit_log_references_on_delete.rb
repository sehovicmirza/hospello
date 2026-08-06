# An audit trail has to outlive what it describes. Both columns are already
# nullable, but without on_delete the constraints block the delete instead:
# destroying a hotel cascades into its users (Hotel has_many :users,
# dependent: :destroy) and raises as soon as any audit row references one.
class NullifyAuditLogReferencesOnDelete < ActiveRecord::Migration[8.0]
  def change
    remove_foreign_key :audit_logs, :hotels
    add_foreign_key :audit_logs, :hotels, on_delete: :nullify

    remove_foreign_key :audit_logs, :users, column: :actor_user_id
    add_foreign_key :audit_logs, :users, column: :actor_user_id, on_delete: :nullify
  end
end
