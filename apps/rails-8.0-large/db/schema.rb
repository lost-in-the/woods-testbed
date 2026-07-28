ActiveRecord::Schema[8.0].define(version: 2024_01_01_000002) do
  create_table "accounts", force: :cascade do |t|
    t.string "name", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "account_events", force: :cascade do |t|
    t.integer "account_id", null: false
    t.string "kind", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_account_events_on_account_id"
  end

  add_foreign_key "account_events", "accounts"
end
