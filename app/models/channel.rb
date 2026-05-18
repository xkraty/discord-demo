class Channel < ApplicationRecord
  # Upsert a row from a Discord channel payload. Tolerates partial payloads
  # (e.g., DMs only carry `recipients`, guild channels carry `name`+`type`).
  # Returns the upserted record or nil if no usable identity could be derived.
  def self.upsert_from_payload(payload)
    return nil unless payload.is_a?(Hash)

    discord_id = payload["id"]
    return nil if discord_id.blank?

    name = derive_name(payload)
    return nil if name.blank?

    record = find_or_initialize_by(discord_channel_id: discord_id)
    record.name         = name if name.present?
    record.channel_type = payload["type"] if payload["type"].present?
    record.raw_payload  = payload
    record.save!
    record
  end

  # Human label for the channel:
  # - Guild text channels (type 0/2/5/...): "#<name>"
  # - DM (type 1): the single recipient's display name
  # - Group DM (type 3): the group name, or joined recipient usernames
  def self.derive_name(payload)
    case payload["type"]
    when 1
      r = (payload["recipients"] || [])[0]
      r && (r["global_name"] || r["username"]) || payload["recipient_username"]
    when 3
      return payload["name"] if payload["name"].present?
      names = (payload["recipients"] || []).map { |r| r["global_name"] || r["username"] }.compact
      names.any? ? names.join(", ") : nil
    else
      payload["name"] && "##{payload["name"]}"
    end
  end
end
