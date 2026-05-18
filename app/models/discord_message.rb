class DiscordMessage < ApplicationRecord
  # Channel name + type are resolved lazily through the Channel table.

  scope :dms, -> { where(is_dm: true).order(captured_at: :desc) }

  # Broadcast new DMs to the dashboard via Turbo Stream + Solid Cable.
  # Only inbound MESSAGE_CREATE (no edits/deletes/channel rows). We prepend
  # the rendered partial to #feed so the newest message lands at the top.
  after_create_commit :broadcast_to_feed, if: :broadcast_to_feed?

  def broadcast_to_feed?
    is_dm && event_type == "MESSAGE_CREATE"
  end

  def broadcast_to_feed
    broadcast_prepend_to(
      "dms",
      target:  "feed",
      partial: "discord_messages/discord_message",
      locals:  { message: self }
    )
  end

  # Human-friendly channel label, falling back gracefully when we
  # haven't seen a CHANNEL_CREATE for this id yet.
  def display_channel_name
    return @display_channel_name if defined?(@display_channel_name)

    @display_channel_name =
      if discord_channel_id.blank?
        nil
      else
        Channel.find_by(discord_channel_id: discord_channel_id)&.name ||
          (is_dm ? "DM" : "##{discord_channel_id}")
      end
  end

  # The Discord raw payload may include a recipient/recipients block for DMs.
  # When present we use it to populate the Channel row.
  def channel_payload_from_raw
    return nil unless raw_payload.is_a?(Hash)

    payload = raw_payload
    {
      "id"         => payload["channel_id"],
      "type"       => is_dm ? 1 : nil,
      "name"       => payload.dig("author", "global_name") || payload.dig("author", "username"),
      "recipients" => is_dm ? [payload["author"]].compact : nil
    }
  end
end
