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

ActiveRecord::Schema[8.0].define(version: 2026_08_11_090000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ai_runs", force: :cascade do |t|
    t.bigint "hotel_id", null: false
    t.bigint "conversation_id"
    t.bigint "message_id"
    t.integer "kind", null: false
    t.string "model"
    t.integer "input_tokens"
    t.integer "output_tokens"
    t.integer "cache_read_tokens"
    t.integer "latency_ms"
    t.integer "status", null: false
    t.integer "cited_kb_entry_ids", default: [], null: false, array: true
    t.string "error_class"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_ai_runs_on_conversation_id"
    t.index ["hotel_id", "created_at"], name: "index_ai_runs_on_hotel_id_and_created_at"
    t.index ["hotel_id", "status", "created_at"], name: "index_ai_runs_on_hotel_id_and_status_and_created_at"
    t.index ["message_id"], name: "index_ai_runs_on_message_id"
  end

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

  create_table "conversations", force: :cascade do |t|
    t.bigint "hotel_id", null: false
    t.bigint "guest_session_id", null: false
    t.bigint "room_id"
    t.integer "channel", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.integer "ai_mode", default: 0, null: false
    t.integer "escalation_reason"
    t.datetime "escalated_at"
    t.string "guest_locale"
    t.datetime "last_guest_message_at"
    t.datetime "last_message_at"
    t.integer "staff_unread_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["guest_session_id"], name: "index_conversations_on_guest_session_id"
    t.index ["guest_session_id"], name: "index_conversations_one_live_per_guest_session", unique: true, where: "(status = ANY (ARRAY[0, 1]))"
    t.index ["hotel_id"], name: "index_conversations_on_hotel_id"
    t.index ["room_id"], name: "index_conversations_on_room_id"
  end

  create_table "departments", force: :cascade do |t|
    t.bigint "hotel_id", null: false
    t.string "name", null: false
    t.boolean "active", default: true, null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["hotel_id", "name"], name: "index_departments_on_hotel_id_and_name", unique: true
    t.index ["hotel_id"], name: "index_departments_on_hotel_id"
  end

  create_table "guest_sessions", force: :cascade do |t|
    t.bigint "hotel_id", null: false
    t.bigint "room_id"
    t.integer "channel", default: 0, null: false
    t.string "token_digest"
    t.string "phone_e164"
    t.string "guest_name", null: false
    t.string "locale", default: "en", null: false
    t.integer "identity_status", default: 0, null: false
    t.datetime "privacy_accepted_at", null: false
    t.integer "status", default: 0, null: false
    t.datetime "last_seen_at"
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["hotel_id", "last_seen_at"], name: "index_guest_sessions_on_hotel_id_and_last_seen_at"
    t.index ["hotel_id", "phone_e164"], name: "index_guest_sessions_on_hotel_id_and_phone_e164", unique: true, where: "(channel = 1)"
    t.index ["hotel_id"], name: "index_guest_sessions_on_hotel_id"
    t.index ["room_id"], name: "index_guest_sessions_on_room_id"
    t.index ["token_digest"], name: "index_guest_sessions_on_token_digest"
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

  create_table "kb_entries", force: :cascade do |t|
    t.bigint "hotel_id", null: false
    t.integer "category", default: 6, null: false
    t.string "title", null: false
    t.text "content", null: false
    t.boolean "published", default: false, null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["hotel_id", "published", "position"], name: "index_kb_entries_on_hotel_id_and_published_and_position"
    t.index ["hotel_id", "title"], name: "index_kb_entries_on_hotel_id_and_title", unique: true
  end

  create_table "messages", force: :cascade do |t|
    t.bigint "hotel_id", null: false
    t.bigint "conversation_id", null: false
    t.integer "sender_role", null: false
    t.bigint "sender_user_id"
    t.text "body", null: false
    t.string "body_locale"
    t.text "translated_body"
    t.string "translated_locale"
    t.integer "translation_status", default: 0, null: false
    t.uuid "client_message_id"
    t.string "external_id"
    t.integer "delivery_status", default: 0, null: false
    t.datetime "delivered_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "visibility", default: 0, null: false
    t.index ["conversation_id", "client_message_id"], name: "index_messages_on_conversation_id_and_client_message_id", unique: true
    t.index ["conversation_id", "id"], name: "index_messages_on_conversation_id_and_id"
    t.index ["conversation_id", "visibility", "id"], name: "index_messages_on_conversation_id_and_visibility_and_id"
    t.index ["external_id"], name: "index_messages_on_external_id", unique: true, where: "(external_id IS NOT NULL)"
    t.index ["hotel_id"], name: "index_messages_on_hotel_id"
    t.index ["sender_user_id"], name: "index_messages_on_sender_user_id"
  end

  create_table "request_categories", force: :cascade do |t|
    t.bigint "hotel_id", null: false
    t.bigint "department_id"
    t.string "key", null: false
    t.string "name", null: false
    t.string "icon"
    t.boolean "active", default: true, null: false
    t.integer "position", default: 0, null: false
    t.jsonb "detail_fields", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["department_id"], name: "index_request_categories_on_department_id"
    t.index ["hotel_id", "key"], name: "index_request_categories_on_hotel_id_and_key", unique: true
    t.index ["hotel_id"], name: "index_request_categories_on_hotel_id"
  end

  create_table "request_events", force: :cascade do |t|
    t.bigint "hotel_id", null: false
    t.bigint "service_request_id", null: false
    t.bigint "user_id"
    t.integer "kind", null: false
    t.integer "from_status"
    t.integer "to_status"
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["service_request_id", "id"], name: "index_request_events_on_service_request_id_and_id"
    t.index ["user_id"], name: "index_request_events_on_user_id"
  end

  create_table "rooms", force: :cascade do |t|
    t.bigint "hotel_id", null: false
    t.string "number", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["hotel_id", "active"], name: "index_rooms_on_hotel_id_and_active"
    t.index ["hotel_id", "number"], name: "index_rooms_on_hotel_id_and_number", unique: true
    t.index ["hotel_id"], name: "index_rooms_on_hotel_id"
  end

  create_table "service_request_drafts", force: :cascade do |t|
    t.bigint "hotel_id", null: false
    t.bigint "conversation_id", null: false
    t.bigint "request_category_id"
    t.jsonb "details", default: {}, null: false
    t.integer "status", default: 0, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_one_live_draft_per_conversation", unique: true, where: "(status = ANY (ARRAY[0, 1]))"
    t.index ["request_category_id"], name: "index_service_request_drafts_on_request_category_id"
    t.index ["status", "expires_at"], name: "index_service_request_drafts_on_status_and_expires_at"
  end

  create_table "service_requests", force: :cascade do |t|
    t.bigint "hotel_id", null: false
    t.bigint "conversation_id"
    t.bigint "guest_session_id"
    t.bigint "room_id"
    t.bigint "request_category_id", null: false
    t.bigint "department_id"
    t.string "summary", null: false
    t.jsonb "details", default: {}, null: false
    t.text "details_original"
    t.string "original_locale"
    t.datetime "requested_for_at"
    t.integer "status", default: 0, null: false
    t.integer "priority", default: 0, null: false
    t.bigint "assigned_to_id"
    t.integer "source", default: 0, null: false
    t.integer "channel", default: 0, null: false
    t.string "dedupe_key", null: false
    t.bigint "acknowledged_by_id"
    t.datetime "acknowledged_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["acknowledged_by_id"], name: "index_service_requests_on_acknowledged_by_id"
    t.index ["assigned_to_id"], name: "index_service_requests_on_assigned_to_id"
    t.index ["conversation_id"], name: "index_service_requests_on_conversation_id"
    t.index ["dedupe_key"], name: "index_service_requests_on_dedupe_key", unique: true
    t.index ["department_id"], name: "index_service_requests_on_department_id"
    t.index ["guest_session_id"], name: "index_service_requests_on_guest_session_id"
    t.index ["hotel_id", "status", "created_at"], name: "index_service_requests_on_hotel_id_and_status_and_created_at"
    t.index ["request_category_id"], name: "index_service_requests_on_request_category_id"
    t.index ["room_id"], name: "index_service_requests_on_room_id"
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

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.binary "payload", null: false
    t.datetime "created_at", null: false
    t.bigint "channel_hash", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
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

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "unanswered_questions", force: :cascade do |t|
    t.bigint "hotel_id", null: false
    t.bigint "conversation_id"
    t.text "question", null: false
    t.text "question_original"
    t.string "locale"
    t.string "normalized_hash", null: false
    t.integer "asked_count", default: 1, null: false
    t.integer "status", default: 0, null: false
    t.bigint "kb_entry_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_unanswered_questions_on_conversation_id"
    t.index ["hotel_id", "normalized_hash"], name: "index_unanswered_questions_on_hotel_id_and_normalized_hash", unique: true
    t.index ["hotel_id", "status", "asked_count"], name: "idx_on_hotel_id_status_asked_count_25dbe93cd3"
    t.index ["kb_entry_id"], name: "index_unanswered_questions_on_kb_entry_id"
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

  create_table "whatsapp_channels", force: :cascade do |t|
    t.bigint "hotel_id", null: false
    t.string "phone_number_e164", null: false
    t.string "phone_number_id", null: false
    t.string "waba_id"
    t.integer "provider", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.string "display_name_status"
    t.datetime "verified_at"
    t.datetime "last_inbound_at"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["hotel_id"], name: "index_whatsapp_channels_on_hotel_id", unique: true
    t.index ["phone_number_e164"], name: "index_whatsapp_channels_on_phone_number_e164", unique: true
    t.index ["phone_number_id"], name: "index_whatsapp_channels_on_phone_number_id", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "ai_runs", "conversations", on_delete: :nullify
  add_foreign_key "ai_runs", "hotels", on_delete: :cascade
  add_foreign_key "ai_runs", "messages", on_delete: :nullify
  add_foreign_key "audit_logs", "hotels", on_delete: :nullify
  add_foreign_key "audit_logs", "users", column: "actor_user_id", on_delete: :nullify
  add_foreign_key "conversations", "guest_sessions", on_delete: :cascade
  add_foreign_key "conversations", "hotels", on_delete: :cascade
  add_foreign_key "conversations", "rooms", on_delete: :nullify
  add_foreign_key "departments", "hotels", on_delete: :cascade
  add_foreign_key "guest_sessions", "hotels", on_delete: :cascade
  add_foreign_key "guest_sessions", "rooms", on_delete: :nullify
  add_foreign_key "kb_entries", "hotels", on_delete: :cascade
  add_foreign_key "messages", "conversations", on_delete: :cascade
  add_foreign_key "messages", "hotels", on_delete: :cascade
  add_foreign_key "messages", "users", column: "sender_user_id", on_delete: :nullify
  add_foreign_key "request_categories", "departments", on_delete: :nullify
  add_foreign_key "request_categories", "hotels", on_delete: :cascade
  add_foreign_key "request_events", "hotels", on_delete: :cascade
  add_foreign_key "request_events", "service_requests", on_delete: :cascade
  add_foreign_key "request_events", "users", on_delete: :nullify
  add_foreign_key "rooms", "hotels", on_delete: :cascade
  add_foreign_key "service_request_drafts", "conversations", on_delete: :cascade
  add_foreign_key "service_request_drafts", "hotels", on_delete: :cascade
  add_foreign_key "service_request_drafts", "request_categories", on_delete: :nullify
  add_foreign_key "service_requests", "conversations", on_delete: :nullify
  add_foreign_key "service_requests", "departments", on_delete: :nullify
  add_foreign_key "service_requests", "guest_sessions", on_delete: :nullify
  add_foreign_key "service_requests", "hotels", on_delete: :cascade
  add_foreign_key "service_requests", "request_categories", on_delete: :restrict
  add_foreign_key "service_requests", "rooms", on_delete: :nullify
  add_foreign_key "service_requests", "users", column: "acknowledged_by_id", on_delete: :nullify
  add_foreign_key "service_requests", "users", column: "assigned_to_id", on_delete: :nullify
  add_foreign_key "sessions", "users"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "unanswered_questions", "conversations", on_delete: :nullify
  add_foreign_key "unanswered_questions", "hotels", on_delete: :cascade
  add_foreign_key "unanswered_questions", "kb_entries", on_delete: :nullify
  add_foreign_key "users", "hotels"
  add_foreign_key "whatsapp_channels", "hotels", on_delete: :cascade
end
