class CreateAckRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :ack_requests do |t|
      t.string   :discord_channel_id, null: false
      t.string   :discord_message_id, null: false
      t.datetime :requested_at,       null: false
      t.datetime :sent_at
      t.text     :error

      t.timestamps
    end

    add_index :ack_requests, [:discord_channel_id, :discord_message_id]
    add_index :ack_requests, :sent_at  # for "unprocessed" queries
  end
end
