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

ActiveRecord::Schema[8.1].define(version: 2026_04_12_060000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "companies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "downgrade_date"
    t.string "external_id"
    t.string "name", null: false
    t.jsonb "settings", default: {}
    t.string "slug", null: false
    t.integer "tier", default: 0, null: false
    t.integer "total_scans_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.date "week_start_date"
    t.integer "weekly_scan_count", default: 0, null: false
    t.index ["external_id"], name: "index_companies_on_external_id", unique: true, where: "(external_id IS NOT NULL)"
    t.index ["slug"], name: "index_companies_on_slug", unique: true
    t.index ["tier"], name: "index_companies_on_tier"
  end

  create_table "data_sync_versions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "file_checksum", null: false
    t.string "file_path", null: false
    t.json "metadata"
    t.integer "record_count"
    t.string "sync_type", null: false
    t.datetime "synced_at"
    t.datetime "updated_at", null: false
    t.index ["sync_type", "file_checksum"], name: "index_data_sync_versions_on_sync_type_and_file_checksum", unique: true
    t.index ["sync_type"], name: "index_data_sync_versions_on_sync_type"
  end

  create_table "detector_results", force: :cascade do |t|
    t.integer "detector_id", null: false
    t.integer "max_score"
    t.integer "passed"
    t.integer "report_id", null: false
    t.integer "total"
    t.index ["detector_id", "report_id"], name: "index_detector_results_on_detector_id_and_report_id", unique: true
    t.index ["detector_id"], name: "index_detector_results_on_detector_id"
    t.index ["report_id"], name: "index_detector_results_on_report_id"
  end

  create_table "detectors", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["deleted_at"], name: "index_detectors_on_deleted_at"
    t.index ["name"], name: "index_detectors_on_name", unique: true
  end

  create_table "environment_variables", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.string "env_name", null: false
    t.text "env_value", null: false
    t.integer "target_id"
    t.datetime "updated_at", null: false
    t.index ["company_id", "target_id", "env_name"], name: "index_env_vars_on_company_target_env_name", unique: true
    t.index ["company_id"], name: "index_environment_variables_on_company_id"
  end

  create_table "memberships", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["company_id"], name: "index_memberships_on_company_id"
    t.index ["user_id", "company_id"], name: "index_memberships_on_user_id_and_company_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "metadata", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key"
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["key"], name: "index_metadata_on_key", unique: true
  end

  create_table "output_servers", force: :cascade do |t|
    t.text "access_token"
    t.json "additional_settings"
    t.text "api_key"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "enabled", default: true
    t.string "endpoint_path"
    t.string "host", null: false
    t.string "name", null: false
    t.text "password"
    t.integer "port"
    t.integer "protocol", default: 0, null: false
    t.integer "server_type", null: false
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["company_id", "name"], name: "index_output_servers_on_company_id_and_name", unique: true
    t.index ["company_id"], name: "index_output_servers_on_company_id"
    t.index ["enabled"], name: "index_output_servers_on_enabled"
    t.index ["server_type"], name: "index_output_servers_on_server_type"
  end

  create_table "probe_results", force: :cascade do |t|
    t.boolean "any_detector_passed", default: false, null: false
    t.json "attempts", default: []
    t.datetime "created_at", null: false
    t.integer "detector_id"
    t.integer "input_tokens", default: 0, null: false
    t.integer "max_score"
    t.integer "output_tokens", default: 0, null: false
    t.integer "passed", default: 0
    t.integer "probe_id", null: false
    t.integer "report_id", null: false
    t.integer "threat_variant_id"
    t.integer "total", default: 0
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_probe_results_on_created_at"
    t.index ["detector_id"], name: "index_probe_results_on_detector_id"
    t.index ["passed"], name: "index_probe_results_on_passed"
    t.index ["probe_id", "created_at", "passed"], name: "index_probe_results_on_probe_id_and_created_at_and_passed"
    t.index ["probe_id"], name: "index_probe_results_on_probe_id"
    t.index ["report_id", "probe_id", "threat_variant_id"], name: "index_probe_results_on_report_probe_variant", unique: true
    t.index ["report_id"], name: "index_probe_results_on_report_id"
    t.index ["threat_variant_id"], name: "index_probe_results_on_threat_variant_id"
  end

  create_table "probe_uploads", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "name", null: false
    t.string "original_filename"
    t.integer "original_size"
    t.integer "probe_count"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_probe_uploads_on_created_at"
    t.index ["probe_count"], name: "index_probe_uploads_on_probe_count"
    t.index ["status"], name: "index_probe_uploads_on_status"
  end

  create_table "probes", force: :cascade do |t|
    t.text "attribution"
    t.bigint "cached_passed_count", default: 0, null: false
    t.bigint "cached_total_count", default: 0, null: false
    t.string "category"
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "detector_id"
    t.integer "disclosure_status"
    t.boolean "enabled", default: true, null: false
    t.string "guid"
    t.integer "input_tokens", default: 0, null: false
    t.date "modified_date"
    t.string "name"
    t.json "prompts", default: []
    t.boolean "published", default: false, null: false
    t.datetime "published_at"
    t.date "release_date"
    t.json "scores", default: {}
    t.integer "social_impact_score"
    t.string "source", default: "community", null: false
    t.text "summary"
    t.datetime "updated_at", null: false
    t.index ["cached_passed_count", "cached_total_count"], name: "index_probes_on_cached_stats"
    t.index ["cached_total_count"], name: "index_probes_on_cached_total_count"
    t.index ["detector_id"], name: "index_probes_on_detector_id"
    t.index ["enabled", "disclosure_status", "release_date"], name: "index_probes_on_tier_filtering"
    t.index ["enabled", "published", "published_at"], name: "index_probes_on_published_filtering"
    t.index ["enabled"], name: "index_probes_on_enabled"
    t.index ["source"], name: "index_probes_on_source"
  end

  create_table "probes_scans", id: false, force: :cascade do |t|
    t.integer "probe_id", null: false
    t.integer "scan_id", null: false
    t.index ["scan_id", "probe_id"], name: "index_probes_scans_on_scan_id_and_probe_id", unique: true
  end

  create_table "probes_taxonomy_categories", id: false, force: :cascade do |t|
    t.integer "probe_id", null: false
    t.integer "taxonomy_category_id", null: false
    t.index ["probe_id", "taxonomy_category_id"], name: "index_probes_taxonomy_categories_unique", unique: true
    t.index ["probe_id"], name: "index_probes_taxonomy_categories_on_probe_id"
    t.index ["taxonomy_category_id"], name: "index_probes_taxonomy_categories_on_taxonomy_category_id"
  end

  create_table "probes_techniques", id: false, force: :cascade do |t|
    t.integer "probe_id", null: false
    t.integer "technique_id", null: false
    t.index ["probe_id", "technique_id"], name: "index_probes_techniques_on_probe_id_and_technique_id", unique: true
    t.index ["probe_id"], name: "index_probes_techniques_on_probe_id"
    t.index ["technique_id"], name: "index_probes_techniques_on_technique_id"
  end

  create_table "raw_report_data", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "jsonl_data", null: false
    t.text "logs_data"
    t.datetime "processed_at"
    t.bigint "report_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_raw_report_data_pending_created_at", where: "(status = 0)"
    t.index ["report_id"], name: "index_raw_report_data_on_report_id", unique: true
  end

  create_table "report_pdfs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "file_path"
    t.bigint "report_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["report_id", "created_at"], name: "index_report_pdfs_on_report_id_and_created_at"
    t.index ["report_id"], name: "index_report_pdfs_on_report_id"
    t.index ["status"], name: "index_report_pdfs_on_status"
  end

  create_table "report_variant_probes", id: false, force: :cascade do |t|
    t.datetime "created_at", precision: nil, null: false
    t.integer "probe_id", null: false
    t.integer "report_id", null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["probe_id"], name: "index_report_variant_probes_on_probe_id"
    t.index ["report_id", "probe_id"], name: "index_report_variant_probes_on_report_and_probe", unique: true
  end

  create_table "reports", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.datetime "end_time"
    t.datetime "heartbeat_at"
    t.datetime "last_retry_at"
    t.text "logs"
    t.string "name", null: false
    t.integer "parent_report_id"
    t.integer "pid"
    t.integer "retry_count", default: 0, null: false
    t.integer "scan_id", null: false
    t.datetime "start_time"
    t.integer "status", default: 0, null: false
    t.integer "target_id", null: false
    t.datetime "updated_at", null: false
    t.string "uuid", null: false
    t.string "variant_probe_name"
    t.index ["company_id"], name: "index_reports_on_company_id"
    t.index ["heartbeat_at"], name: "index_reports_on_heartbeat_running_only", where: "(status = 1)"
    t.index ["parent_report_id"], name: "index_reports_on_parent_report_id"
    t.index ["parent_report_id"], name: "index_reports_on_unique_parent_report_id", unique: true, where: "(parent_report_id IS NOT NULL)"
    t.index ["scan_id"], name: "index_reports_on_scan_id"
    t.index ["status", "parent_report_id"], name: "index_reports_on_active_with_parent", where: "(status = ANY (ARRAY[1, 6]))"
    t.index ["status"], name: "index_reports_on_status"
    t.index ["target_id"], name: "index_reports_on_target_id"
    t.index ["uuid"], name: "index_reports_on_uuid", unique: true
    t.index ["variant_probe_name"], name: "index_reports_on_variant_probe_name"
  end

  create_table "scans", force: :cascade do |t|
    t.boolean "auto_update_cm", default: false, null: false
    t.boolean "auto_update_generic", default: false, null: false
    t.boolean "auto_update_hp", default: false, null: false
    t.decimal "avg_successful_attacks", precision: 10, scale: 2
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "next_scheduled_run"
    t.integer "output_server_id"
    t.boolean "priority", default: false, null: false
    t.json "recurrence"
    t.integer "reports_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "uuid", null: false
    t.index ["auto_update_cm"], name: "index_scans_on_auto_update_cm"
    t.index ["auto_update_generic"], name: "index_scans_on_auto_update_generic"
    t.index ["auto_update_hp"], name: "index_scans_on_auto_update_hp"
    t.index ["avg_successful_attacks"], name: "index_scans_on_avg_successful_attacks"
    t.index ["company_id"], name: "index_scans_on_company_id"
    t.index ["output_server_id"], name: "index_scans_on_output_server_id"
    t.index ["reports_count"], name: "index_scans_on_reports_count"
    t.index ["uuid"], name: "index_scans_on_uuid", unique: true
  end

  create_table "scans_targets", id: false, force: :cascade do |t|
    t.integer "scan_id", null: false
    t.integer "target_id", null: false
    t.index ["scan_id", "target_id"], name: "index_scans_targets_on_scan_id_and_target_id", unique: true
  end

  create_table "scans_threat_variant_subindustries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "scan_id", null: false
    t.integer "threat_variant_subindustry_id", null: false
    t.datetime "updated_at", null: false
    t.index ["scan_id", "threat_variant_subindustry_id"], name: "index_scan_variant_subindustries", unique: true
    t.index ["scan_id"], name: "index_scans_threat_variant_subindustries_on_scan_id"
    t.index ["threat_variant_subindustry_id"], name: "idx_on_threat_variant_subindustry_id_9fdd9f8398"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.bigint "channel_hash", null: false
    t.datetime "created_at", null: false
    t.binary "payload", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "targets", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.text "description"
    t.text "json_config"
    t.string "model", null: false
    t.string "model_type", null: false
    t.string "name", null: false
    t.integer "status", default: 0, null: false
    t.integer "target_type", default: 0, null: false
    t.decimal "tokens_per_second", precision: 10, scale: 2
    t.integer "tokens_per_second_sample_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.text "validation_text"
    t.text "web_config"
    t.index ["company_id", "name"], name: "index_targets_on_company_id_and_name", unique: true
    t.index ["company_id"], name: "index_targets_on_company_id"
    t.index ["deleted_at"], name: "index_targets_on_deleted_at"
    t.index ["status"], name: "index_targets_on_status"
    t.index ["target_type"], name: "index_targets_on_target_type"
    t.index ["tokens_per_second"], name: "index_targets_on_tokens_per_second", where: "(tokens_per_second IS NOT NULL)"
  end

  create_table "taxonomy_categories", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_taxonomy_categories_on_name", unique: true
  end

  create_table "techniques", force: :cascade do |t|
    t.string "name"
    t.string "path"
  end

  create_table "threat_variant_industries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_threat_variant_industries_on_name", unique: true
  end

  create_table "threat_variant_subindustries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "threat_variant_industry_id", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_threat_variant_subindustries_on_name"
    t.index ["threat_variant_industry_id", "name"], name: "index_tv_subindustries_on_industry_and_name", unique: true
    t.index ["threat_variant_industry_id"], name: "idx_on_threat_variant_industry_id_2b929fcfbe"
  end

  create_table "threat_variants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "key_changes"
    t.integer "position"
    t.integer "probe_id", null: false
    t.text "prompt"
    t.text "rationale"
    t.integer "threat_variant_subindustry_id", null: false
    t.datetime "updated_at", null: false
    t.index ["probe_id", "prompt"], name: "index_threat_variants_on_probe_and_prompt", unique: true
    t.index ["probe_id", "threat_variant_subindustry_id"], name: "index_tv_on_probe_and_subindustry"
    t.index ["probe_id"], name: "index_threat_variants_on_probe_id"
    t.index ["prompt"], name: "index_threat_variants_on_prompt"
    t.index ["threat_variant_subindustry_id"], name: "index_threat_variants_on_threat_variant_subindustry_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "current_company_id"
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "external_id"
    t.integer "failed_attempts", default: 0, null: false
    t.datetime "locked_at"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.boolean "super_admin", default: false, null: false
    t.string "time_zone"
    t.string "unlock_token"
    t.datetime "updated_at", null: false
    t.index ["current_company_id"], name: "index_users_on_current_company_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["external_id"], name: "index_users_on_external_id", unique: true, where: "(external_id IS NOT NULL)"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["super_admin"], name: "index_users_on_super_admin"
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "detector_results", "detectors"
  add_foreign_key "detector_results", "reports"
  add_foreign_key "environment_variables", "companies"
  add_foreign_key "memberships", "companies"
  add_foreign_key "memberships", "users"
  add_foreign_key "output_servers", "companies"
  add_foreign_key "probe_results", "detectors"
  add_foreign_key "probe_results", "probes"
  add_foreign_key "probe_results", "reports"
  add_foreign_key "probe_results", "threat_variants"
  add_foreign_key "probes", "detectors"
  add_foreign_key "probes_scans", "probes"
  add_foreign_key "probes_scans", "scans"
  add_foreign_key "probes_taxonomy_categories", "probes"
  add_foreign_key "probes_taxonomy_categories", "taxonomy_categories"
  add_foreign_key "probes_techniques", "probes"
  add_foreign_key "probes_techniques", "techniques"
  add_foreign_key "raw_report_data", "reports", on_delete: :cascade
  add_foreign_key "report_pdfs", "reports"
  add_foreign_key "reports", "companies"
  add_foreign_key "reports", "reports", column: "parent_report_id"
  add_foreign_key "reports", "scans"
  add_foreign_key "reports", "targets"
  add_foreign_key "scans", "companies"
  add_foreign_key "scans", "output_servers"
  add_foreign_key "scans_targets", "scans"
  add_foreign_key "scans_targets", "targets"
  add_foreign_key "scans_threat_variant_subindustries", "scans"
  add_foreign_key "scans_threat_variant_subindustries", "threat_variant_subindustries"
  add_foreign_key "targets", "companies"
  add_foreign_key "threat_variant_subindustries", "threat_variant_industries"
  add_foreign_key "threat_variants", "probes"
  add_foreign_key "threat_variants", "threat_variant_subindustries"
  add_foreign_key "users", "companies", column: "current_company_id"
end
