# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_08_06_142813) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "audit_logs", force: :cascade do |t|
    t.bigint "actor_user_id"
    t.bigint "hotel_id"
    t.string "action", null: false
    t.string "target_type"
    t.bigint "target_id"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["actor_user_id"], name: "index_audit_logs_on_actor_user_id"
    t.index ["hotel_id", "created_at"], name: "index_audit_logs_on_hotel_id_and_created_at"
  end

  create_table "hotels", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.string "timezone", default: "Europe/Sarajevo", null: false
    t.string "staff_locale", default: "en", null: false
    t.integer "status", default: 0, null: false
    t.string "primary_color", default: "#1F3A5F", null: false
    t.string "secondary_color", default: "#C9A227", null: false
    t.string "concierge_name"
    t.text "welcome_message"
    t.string "contact_phone"
    t.text "contact_notes"
    t.string "checkout_time"
    t.string "escalation_email"
    t.boolean "powered_by_visible", default: true, null: false
    t.boolean "ai_enabled", default: true, null: false
    t.integer "ai_daily_token_budget", default: 500000, null: false
    t.integer "overdue_after_minutes", default: 120, null: false
    t.jsonb "settings", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_hotels_on_slug", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "token", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token"], name: "index_sessions_on_token", unique: true
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.binary "key", null: false
    t.binary "value", null: false
    t.datetime "created_at", null: false
    t.bigint "key_hash", null: false
    t.integer "byte_size", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.bigint "hotel_id"
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.string "name", null: false
    t.integer "role", default: 0, null: false
    t.string "locale", default: "en", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.index ["hotel_id", "role"], name: "index_users_on_hotel_id_and_role"
  end

  add_foreign_key "audit_logs", "hotels"
  add_foreign_key "audit_logs", "users", column: "actor_user_id"
  add_foreign_key "sessions", "users"
  add_foreign_key "users", "hotels"
end
