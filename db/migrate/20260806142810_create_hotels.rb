class CreateHotels < ActiveRecord::Migration[8.0]
  def change
    create_table :hotels do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :timezone, null: false, default: "Europe/Sarajevo"
      t.string :staff_locale, null: false, default: "en"
      t.integer :status, null: false, default: 0

      # Branding shown to guests in the chat.
      t.string :primary_color, null: false, default: "#1F3A5F"
      t.string :secondary_color, null: false, default: "#C9A227"
      t.string :concierge_name
      t.text :welcome_message

      # Hotel-side contact details the concierge can quote or escalate to.
      t.string :contact_phone
      t.text :contact_notes
      t.string :checkout_time
      t.string :escalation_email

      t.boolean :powered_by_visible, null: false, default: true
      t.boolean :ai_enabled, null: false, default: true
      t.integer :ai_daily_token_budget, null: false, default: 500_000
      t.integer :overdue_after_minutes, null: false, default: 120
      t.jsonb :settings, null: false, default: {}

      t.timestamps
    end

    add_index :hotels, :slug, unique: true
  end
end
