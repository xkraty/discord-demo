# Routes a single event from the Chrome extension's POST /capture/ingest
# batch into the right table:
#
#   - gateway_frame  with t ∈ MESSAGE_T → DiscordMessage upsert + Channel update
#   - gateway_frame  with t == MESSAGE_ACK → ChannelReadState upsert
#   - gateway_session                  → DiscordSessionEvent insert
#   - gateway_raw    (parse failed)    → DiscordSessionEvent("raw_frame")
#   - anything else                    → DiscordSessionEvent("unknown_kind")
#
# Idempotency is enforced at the DB level by the UNIQUE constraint on
# (discord_message_id, event_type). Retried batches are safe.
class CaptureIngestService
  MESSAGE_T = %w[MESSAGE_CREATE MESSAGE_UPDATE MESSAGE_DELETE CHANNEL_CREATE].freeze

  def initialize(event)
    @event = event || {}
    @kind  = @event["kind"]
  end

  def call
    case @kind
    when "gateway_frame"   then ingest_frame
    when "gateway_session" then ingest_session
    when "gateway_raw"     then ingest_raw
    else
      ingest_unknown
    end
  end

  private

  def ingest_frame
    frame = @event["frame"]
    return false unless frame.is_a?(Hash)

    t = frame["t"]
    d = frame["d"]
    return false unless t.is_a?(String) && d.is_a?(Hash)

    case
    when MESSAGE_T.include?(t)
      insert_message(t, d)
      maybe_upsert_channel_from_frame(t, d)
      true
    when t == "MESSAGE_ACK"
      upsert_read_state(d)
      true
    else
      # Other event types (READY, PRESENCE_UPDATE, heartbeats) — record as
      # session events for visibility. detail = a tiny JSON summary.
      DiscordSessionEvent.create!(
        event:       t,
        detail:      summarize_session_payload(d),
        ws_id:       @event["ws_id"],
        occurred_at: parse_time(@event["received_at"]) || Time.current,
        raw_payload: frame
      )
      true
    end
  end

  def insert_message(event_type, d)
    discord_message_id =
      if event_type == "CHANNEL_CREATE"
        # CHANNEL_CREATE doesn't have a message id; synthesize one keyed on
        # the channel id so the unique constraint keeps the audit log clean.
        "channel:#{d["id"]}"
      else
        d["id"]
      end
    return false if discord_message_id.blank?

    # We use create! (not upsert) so after_create_commit fires for Turbo
    # broadcasts. Duplicates are rejected at the DB level by the UNIQUE
    # constraint; we rescue and treat them as "already accepted".
    DiscordMessage.create!(
      event_type:          event_type,
      discord_message_id:  discord_message_id,
      discord_channel_id:  d["channel_id"] || d["id"],
      discord_author_id:   d.dig("author", "id"),
      author_username:     d.dig("author", "username"),
      author_display_name: d.dig("author", "global_name") || d.dig("author", "display_name"),
      content:             d["content"],
      timestamp_iso:       d["timestamp"],
      is_dm:               d["guild_id"].nil?,
      raw_payload:         d,
      captured_at:         Time.current,
      ws_id:               @event["ws_id"],
      received_at:         parse_time(@event["received_at"])
    )
  rescue ActiveRecord::RecordNotUnique
    # Idempotent retry — the row already exists; not an error.
    true
  end

  def maybe_upsert_channel_from_frame(event_type, d)
    if event_type == "CHANNEL_CREATE"
      Channel.upsert_from_payload(d)
    else
      # MESSAGE_CREATE for a DM carries the recipient inside `d.author`.
      # Synthesize a minimal payload so we can label future messages with
      # the DM partner's name.
      return unless d["guild_id"].nil? && d["channel_id"].present?

      Channel.upsert_from_payload(
        "id"         => d["channel_id"],
        "type"       => 1,
        "recipients" => [ d["author"] ].compact
      )
    end
  end

  def upsert_read_state(d)
    channel_id = d["channel_id"]
    return false if channel_id.blank?

    incoming_version = d["version"].to_i
    state = ChannelReadState.find_or_initialize_by(discord_channel_id: channel_id)
    if state.new_record? || incoming_version > state.ack_version
      state.ack_version          = incoming_version
      state.last_read_message_id = d["message_id"]
      state.last_read_at         = Time.current
      state.save!
    end
    true
  end

  def ingest_session
    DiscordSessionEvent.create!(
      event:       @event["event"].to_s,
      detail:      @event["detail"],
      ws_id:       @event["ws_id"],
      occurred_at: parse_time(@event["occurred_at"]) || Time.current
    )
    true
  end

  def ingest_raw
    DiscordSessionEvent.create!(
      event:       "raw_frame",
      detail:      @event["text"]&.slice(0, 1000),
      ws_id:       @event["ws_id"],
      occurred_at: parse_time(@event["received_at"]) || Time.current
    )
    true
  end

  def ingest_unknown
    DiscordSessionEvent.create!(
      event:       "unknown_kind",
      detail:      @kind.to_s.slice(0, 200),
      occurred_at: Time.current
    )
    true
  end

  def summarize_session_payload(d)
    keys = d.keys.first(8)
    {
      user_id:               d.dig("user", "id"),
      session_id:            d["session_id"],
      private_channel_count: (d["private_channels"]&.length),
      guild_count:           (d["guilds"]&.length),
      keys:                  keys
    }.compact.to_json
  rescue
    nil
  end

  def parse_time(value)
    return nil if value.blank?
    Time.parse(value)
  rescue ArgumentError
    nil
  end
end
