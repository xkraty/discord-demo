class CreateDiscordSessionEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :discord_session_events do |t|
      t.string   :event,         null: false
      t.text     :detail
      t.integer  :ws_id
      t.datetime :occurred_at,   null: false
      t.jsonb    :raw_payload

      t.timestamps
    end

    add_index :discord_session_events, :occurred_at
    add_index :discord_session_events, :event
  end
end
