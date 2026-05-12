# frozen_string_literal: true

require "dotenv/load"
require "playwright"
require_relative "db"
require_relative "browser"
require_relative "gateway"
require_relative "logger"

Log.info("capture_start")

DB.init!
DB.record_session_event("capture_start", "pid=#{Process.pid}")

shutdown = false
trap("INT")  { shutdown = true; Log.warn("signal_received", signal: "INT") }
trap("TERM") { shutdown = true; Log.warn("signal_received", signal: "TERM") }

begin
  Playwright.create(playwright_cli_executable_path: "npx playwright") do |pw|
    page, context = Browser.connect(pw)
    Log.info("browser_ready", url: page.url)

    ws_listener = ->(ws) {
      if ws.url.to_s.include?("gateway")
        Log.info("gateway_open", url: ws.url)
        DB.record_session_event("gateway_open", ws.url.to_s)
        Gateway.register_websocket(ws)
      end
    }

    page.on("websocket", ws_listener)

    # Also bind to any future pages in this context (e.g. Discord logout
    # navigates to /login which may create a new page object).
    context.on("page", ->(new_page) {
      Log.info("page_created", url: new_page.url)
      DB.record_session_event("page_created", new_page.url.to_s)
      new_page.on("websocket", ws_listener)
    })

    # Reload forces Discord to re-open its gateway WebSocket, which fires the
    # listener registered above. Without this, the already-open WebSocket from
    # the manual login step is invisible to page.on("websocket").
    Log.info("browser_reload", reason: "reattach_gateway_ws")
    page.reload(waitUntil: "domcontentloaded")

    Log.info("listening", note: "waiting_for_gateway_frames")

    loop do
      break if shutdown
      Gateway.check_closed_websockets
      DB.record_session_event("heartbeat", nil)
      Log.info("heartbeat")
      30.times do
        break if shutdown
        sleep 1
      end
    end

    DB.record_session_event("capture_stop", "pid=#{Process.pid}")
    Log.info("capture_stop")
  end
rescue => e
  Log.warn("fatal_error", error: e.class, msg: e.message.slice(0, 200))
  DB.record_session_event("error", "#{e.class}: #{e.message.slice(0, 200)}")
  raise
end
