class CreateOutboundMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :outbound_messages do |t|
      t.string :discord_channel_id, null: false
      t.text :body, null: false
      t.datetime :queued_at, null: false
      t.datetime :sent_at

      t.timestamps
    end
    add_index :outbound_messages, :discord_channel_id
  end
end
