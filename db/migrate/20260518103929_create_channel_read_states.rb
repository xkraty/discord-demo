class CreateChannelReadStates < ActiveRecord::Migration[8.1]
  def change
    create_table :channel_read_states do |t|
      t.string   :discord_channel_id,   null: false
      t.string   :last_read_message_id
      t.datetime :last_read_at
      t.integer  :ack_version,          null: false, default: 0

      t.timestamps
    end

    add_index :channel_read_states, :discord_channel_id, unique: true
  end
end
