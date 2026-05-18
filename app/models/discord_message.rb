class DiscordMessage < ApplicationRecord
  # Channel name + type are resolved lazily through the Channel table.
  # Solid Cable + turbo-rails broadcasting hooks live in Step 7; the
  # broadcast callback is added then.

  scope :dms, -> { where(is_dm: true).order(captured_at: :desc) }

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
