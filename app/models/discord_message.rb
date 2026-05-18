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

  # --- Attachment / embed / sticker / reply helpers ----------------------
  #
  # All of these read from raw_payload and return plain hashes/strings the
  # view can render. We don't persist them as separate AR rows in v1 —
  # raw_payload is the source of truth and is small enough to read on
  # render. If write volume grows we can extract to dedicated columns.

  IMAGE_CONTENT_TYPES = %w[image/png image/jpeg image/jpg image/gif image/webp image/avif image/svg+xml].freeze
  VIDEO_CONTENT_TYPES = %w[video/mp4 video/webm video/quicktime video/x-matroska].freeze

  def attachments
    @attachments ||= Array(raw_payload["attachments"]).map { |a| Attachment.new(a) }
  end

  def stickers
    @stickers ||= Array(raw_payload["sticker_items"]).map { |s| Sticker.new(s) }
  end

  # Embeds — for v1 we don't try to render rich previews. We extract the
  # canonical URL of each embed so the view can render them as plain links
  # alongside the message content.
  def embed_urls
    @embed_urls ||= Array(raw_payload["embeds"]).map { |e| e["url"] }.compact.uniq
  end

  # Reply context. When this message was a reply, Discord inlines the
  # full original message under `referenced_message`. We expose it as a
  # tiny struct so the view can render a quote block above.
  def reply_context
    return nil unless raw_payload.is_a?(Hash)
    ref = raw_payload["referenced_message"]
    return nil unless ref.is_a?(Hash)

    Reply.new(ref)
  end

  # Light wrapper around an attachment hash with media-type classification.
  class Attachment
    attr_reader :raw

    def initialize(raw)
      @raw = raw.is_a?(Hash) ? raw : {}
    end

    def url        = @raw["proxy_url"].presence || @raw["url"]
    def filename   = @raw["filename"] || @raw["title"] || "attachment"
    def size       = @raw["size"].to_i
    def width      = @raw["width"]
    def height     = @raw["height"]
    def content_type = @raw["content_type"].to_s

    def image?
      ct = content_type.split(";").first.to_s.downcase
      IMAGE_CONTENT_TYPES.include?(ct) || filename =~ /\.(png|jpe?g|gif|webp|avif|svg)\z/i
    end

    def video?
      ct = content_type.split(";").first.to_s.downcase
      VIDEO_CONTENT_TYPES.include?(ct) || filename =~ /\.(mp4|webm|mov|mkv)\z/i
    end

    def audio?
      content_type.start_with?("audio/")
    end

    # Human-readable size, e.g. "2.4 MB"
    def human_size
      return nil if size.zero?
      ActiveSupport::NumberHelper.number_to_human_size(size)
    end
  end

  # Discord sticker CDN URL. Format type 1=png, 2=apng, 3=lottie, 4=gif.
  # We render 1/2/4 as <img> from the CDN; 3 (Lottie JSON) we skip
  # because rendering needs a JS player we'd rather not pull in.
  class Sticker
    EXTENSIONS = { 1 => "png", 2 => "png", 3 => "json", 4 => "gif" }.freeze

    attr_reader :raw

    def initialize(raw)
      @raw = raw.is_a?(Hash) ? raw : {}
    end

    def id   = @raw["id"]
    def name = @raw["name"] || "sticker"
    def format_type = @raw["format_type"].to_i

    def url
      ext = EXTENSIONS[format_type] || "png"
      return nil if id.blank?
      "https://media.discordapp.net/stickers/#{id}.#{ext}"
    end

    def renderable_as_image?
      [1, 2, 4].include?(format_type) && id.present?
    end
  end

  # Quote-block info for a reply.
  class Reply
    attr_reader :raw

    def initialize(raw)
      @raw = raw.is_a?(Hash) ? raw : {}
    end

    def author_display = @raw.dig("author", "global_name") || @raw.dig("author", "username") || "(unknown)"
    def content        = @raw["content"]
    def has_attachments? = Array(@raw["attachments"]).any?
  end
end
