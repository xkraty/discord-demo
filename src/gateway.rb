# frozen_string_literal: true

require "json"
require "zlib"
require "fileutils"
require_relative "db"
require_relative "logger"

module Gateway
  RAW_FRAMES_DIR  = File.expand_path("../../data/raw-frames", __FILE__)
  DISPATCH_EVENTS = %w[MESSAGE_CREATE MESSAGE_UPDATE MESSAGE_DELETE].freeze

  # One persistent Zlib::Inflate per WebSocket connection (zlib-stream shares
  # context across frames; resetting per frame would break decompression).
  @inflaters = {}

  class << self
    def register_websocket(ws)
      ws_id = ws.object_id
      @inflaters[ws_id] = Zlib::Inflate.new(Zlib::MAX_WBITS)

      ws.on("framereceived", ->(payload) {
        handle_frame(payload, ws_id)
      })

      ws.on("close", ->(*) {
        cleanup_inflater(ws_id)
        Log.warn("gateway_close")
        DB.record_session_event("gateway_close", nil)
      })
    end

    def handle_frame(payload, ws_id)
      # playwright-ruby-client passes frame data as a hash with :body key
      data = payload.is_a?(Hash) ? (payload[:body] || payload["body"]) : payload
      return if data.nil? || (data.respond_to?(:empty?) && data.empty?)

      parsed = try_json(data)
      if parsed
        dispatch(parsed)
        return
      end

      inflater = @inflaters[ws_id]
      if inflater && data.is_a?(String)
        begin
          decompressed = inflater.inflate(data)
          parsed = JSON.parse(decompressed)
          dispatch(parsed)
          return
        rescue Zlib::Error, JSON::ParserError => e
          Log.warn("frame_decompress_failed", error: e.class, msg: e.message.slice(0, 80))
        end
      end

      write_raw_frame(data)
    rescue => e
      Log.warn("handle_frame_error", error: e.class, msg: e.message.slice(0, 120))
    end

    private

    def try_json(data)
      return nil unless data.is_a?(String)
      JSON.parse(data)
    rescue JSON::ParserError
      nil
    end

    def dispatch(frame)
      t = frame["t"]
      return unless DISPATCH_EVENTS.include?(t)

      d = frame["d"]
      return unless d.is_a?(Hash)

      is_dm = d["guild_id"].nil?

      DB.insert_event(event_type: t, payload: d)

      if is_dm
        Log.info(t,
          message_id: d["id"],
          channel_id: d["channel_id"],
          author:     d.dig("author", "username") || "(unknown)",
          preview:    d["content"]&.slice(0, 60)&.inspect
        )
      end
    end

    def write_raw_frame(data)
      FileUtils.mkdir_p(RAW_FRAMES_DIR)
      date_str  = Time.now.utc.strftime("%Y-%m-%d")
      bin_path  = File.join(RAW_FRAMES_DIR, "#{date_str}.bin")
      raw_bytes = data.is_a?(String) ? data.b : data.to_s.b
      File.open(bin_path, "ab") do |f|
        f.write([raw_bytes.bytesize].pack("N"))
        f.write(raw_bytes)
      end
    rescue => e
      Log.warn("raw_frame_write_failed", error: e.class, msg: e.message.slice(0, 80))
    end

    def cleanup_inflater(ws_id)
      inf = @inflaters.delete(ws_id)
      inf&.close rescue nil
    end
  end
end
