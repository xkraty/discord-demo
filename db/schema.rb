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

ActiveRecord::Schema[8.1].define(version: 2026_05_21_130734) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "ack_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "discord_channel_id", null: false
    t.string "discord_message_id", null: false
    t.text "error"
    t.datetime "requested_at", null: false
    t.datetime "sent_at"
    t.datetime "updated_at", null: false
    t.index ["discord_channel_id", "discord_message_id"], name: "idx_on_discord_channel_id_discord_message_id_3c5b2b982e"
    t.index ["sent_at"], name: "index_ack_requests_on_sent_at"
  end

  create_table "channel_read_states", force: :cascade do |t|
    t.integer "ack_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "discord_channel_id", null: false
    t.datetime "last_read_at"
    t.string "last_read_message_id"
    t.datetime "updated_at", null: false
    t.index ["discord_channel_id"], name: "index_channel_read_states_on_discord_channel_id", unique: true
  end

  create_table "channels", force: :cascade do |t|
    t.integer "channel_type"
    t.datetime "created_at", null: false
    t.string "discord_channel_id", null: false
    t.string "name"
    t.jsonb "raw_payload"
    t.datetime "updated_at", null: false
    t.index ["discord_channel_id"], name: "index_channels_on_discord_channel_id", unique: true
  end

  create_table "discord_messages", force: :cascade do |t|
    t.string "author_display_name"
    t.string "author_username"
    t.datetime "captured_at", null: false
    t.text "content"
    t.datetime "created_at", null: false
    t.string "discord_author_id"
    t.string "discord_channel_id"
    t.string "discord_message_id", null: false
    t.string "event_type", null: false
    t.boolean "is_dm", default: false, null: false
    t.jsonb "raw_payload", null: false
    t.datetime "received_at"
    t.string "timestamp_iso"
    t.datetime "updated_at", null: false
    t.integer "ws_id"
    t.index ["discord_channel_id"], name: "index_discord_messages_on_discord_channel_id"
    t.index ["discord_message_id", "event_type"], name: "idx_discord_messages_id_type", unique: true
    t.index ["is_dm", "captured_at"], name: "index_discord_messages_on_is_dm_and_captured_at"
  end

  create_table "discord_session_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "detail"
    t.string "event", null: false
    t.datetime "occurred_at", null: false
    t.jsonb "raw_payload"
    t.datetime "updated_at", null: false
    t.integer "ws_id"
    t.index ["event"], name: "index_discord_session_events_on_event"
    t.index ["occurred_at"], name: "index_discord_session_events_on_occurred_at"
  end

  create_table "orders", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "order_number", null: false
    t.date "ordered_at"
    t.bigint "product_id", null: false
    t.string "size"
    t.integer "sold_price_cents"
    t.datetime "updated_at", null: false
    t.index ["order_number"], name: "index_orders_on_order_number"
    t.index ["product_id"], name: "index_orders_on_product_id"
  end

  create_table "products", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "sku", null: false
    t.datetime "updated_at", null: false
    t.index ["sku"], name: "index_products_on_sku", unique: true
  end

  add_foreign_key "orders", "products"
end
