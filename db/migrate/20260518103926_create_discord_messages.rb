class CreateDiscordMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :discord_messages do |t|
      t.string   :event_type,           null: false
      t.string   :discord_message_id,   null: false
      t.string   :discord_channel_id
      t.string   :discord_author_id
      t.string   :author_username
      t.string   :author_display_name
      t.text     :content
      t.string   :timestamp_iso
      t.boolean  :is_dm,                null: false, default: false
      t.jsonb    :raw_payload,          null: false
      t.datetime :captured_at,          null: false
      t.integer  :ws_id
      t.datetime :received_at

      t.timestamps
    end

    add_index :discord_messages,
              [ :discord_message_id, :event_type ],
              unique: true,
              name: "idx_discord_messages_id_type"
    add_index :discord_messages, [ :is_dm, :captured_at ]
    add_index :discord_messages, :discord_channel_id
  end
end
