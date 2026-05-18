class CreateChannels < ActiveRecord::Migration[8.1]
  def change
    create_table :channels do |t|
      t.string  :discord_channel_id, null: false
      t.string  :name
      t.integer :channel_type
      t.jsonb   :raw_payload

      t.timestamps
    end

    add_index :channels, :discord_channel_id, unique: true
  end
end
