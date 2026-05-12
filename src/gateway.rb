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
  @inflaters       = {}
  @websockets      = {}   # ws_id => ws (for closed? polling)
  @closed_reported = {}   # ws_id => true once gateway_close recorded

  class << self
    def register_websocket(ws)
      ws_id = ws.object_id
      @inflaters[ws_id]  = Zlib::Inflate.new(Zlib::MAX_WBITS)
      @websockets[ws_id] = ws

      ws.on("framereceived", ->(payload) {
        handle_frame(payload, ws_id)
      })

      ws.on("close", ->(*) {
        record_close(ws_id, "close_event")
      })

      ws.on("socketerror", ->(err) {
        Log.warn("gateway_error", error: err.to_s.slice(0, 120))
        DB.record_session_event("gateway_error", err.to_s.slice(0, 200))
        record_close(ws_id, "socketerror")
      })
    end

    # Called periodically from the heartbeat loop. Catches close events that
    # the Playwright Node bridge silently dropped (a known quirk with
    # connect_over_cdp).
    def check_closed_websockets
      @websockets.each do |ws_id, ws|
        next if @closed_reported[ws_id]
        closed = false
        begin
          closed = ws.closed?
        rescue => e
          Log.warn("ws_closed_check_failed", ws_id: ws_id, error: e.class)
          closed = true  # treat as closed if we can't even ask
        end
        record_close(ws_id, "poll_detected") if closed
      end
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

    def record_close(ws_id, source)
      return if @closed_reported[ws_id]
      @closed_reported[ws_id] = true
      cleanup_inflater(ws_id)
      Log.warn("gateway_close", source: source)
      DB.record_session_event("gateway_close", source)
    end
  end
end
