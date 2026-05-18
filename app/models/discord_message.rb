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

  # Embeds — rich preview cards. Discord bots send their main content this
  # way: title, description, fields, color stripe, thumbnail. We wrap each
  # payload entry in a RichEmbed so the view can render it without scraping
  # the raw hash inline.
  def embeds
    @embeds ||= Array(raw_payload["embeds"]).map { |e| RichEmbed.new(e) }
  end

  # True when the message has nothing visible: no text content, no
  # attachments, no stickers, no usable embeds. Used to decide whether to
  # show a "(no text content)" placeholder.
  def renderable_body?
    content.present? || attachments.any? || stickers.any? || embeds.any?(&:any_content?)
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

  # Wrapper around a Discord rich embed. Bots use these as their primary
  # content surface, so we render the lot: title (linked when url present),
  # description, fields, author, footer, thumbnail. Discord encodes the
  # accent color as a decimal integer; we convert to a #rrggbb hex string
  # for the CSS left-border stripe.
  class RichEmbed
    attr_reader :raw

    def initialize(raw)
      @raw = raw.is_a?(Hash) ? raw : {}
    end

    def type        = @raw["type"]
    def title       = @raw["title"]
    def description = @raw["description"]
    def url         = @raw["url"]

    def color_hex
      c = @raw["color"]
      return nil if c.nil? || c.zero?
      "#%06x" % c.to_i
    end

    def thumbnail_url = @raw.dig("thumbnail", "proxy_url") || @raw.dig("thumbnail", "url")
    def image_url     = @raw.dig("image", "proxy_url") || @raw.dig("image", "url")
    def video_url     = @raw.dig("video", "url")

    def author_name = @raw.dig("author", "name")
    def author_url  = @raw.dig("author", "url")

    def footer_text = @raw.dig("footer", "text")
    def timestamp   = @raw["timestamp"]

    def fields
      Array(@raw["fields"]).map { |f| EmbedField.new(f) }
    end

    # True when this embed has anything renderable. Discord sometimes sends
    # empty placeholder embeds (e.g. when a link is detected but the
    # unfurler returned nothing); we hide those.
    def any_content?
      title.present? || description.present? || url.present? ||
        fields.any? || image_url.present? || thumbnail_url.present? ||
        author_name.present? || footer_text.present?
    end
  end

  class EmbedField
    attr_reader :raw

    def initialize(raw)
      @raw = raw.is_a?(Hash) ? raw : {}
    end

    def name   = @raw["name"]
    def value  = @raw["value"]
    def inline = !!@raw["inline"]
  end
end
