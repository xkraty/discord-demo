# frozen_string_literal: true

require "playwright"
require "json"
require_relative "logger"

module Browser
  NOVNC_URL    = "http://localhost:3010"
  COOKIES_PATH = File.expand_path("../../data/discord-cookies.json", __FILE__)

  def self.connect(playwright_instance)
    cdp_url = ENV.fetch("CHROMIUM_CDP_URL", "http://localhost:9222")

    Log.info("browser_connect", cdp_url: cdp_url)
    browser = playwright_instance.chromium.connect_over_cdp(cdp_url)

    context = browser.contexts.first || browser.new_context
    page    = context.pages.first    || context.new_page

    inject_cookies(context)

    # Token injection requires being on the discord.com origin first (same-origin
    # policy on localStorage), then setting the token, then loading the SPA so
    # its init code finds the token already in place. Order:
    #   1. Navigate to a tiny discord.com URL we know returns quickly
    #   2. Set localStorage.token via page.evaluate (now on the right origin)
    #   3. Navigate to /channels/@me — Discord's web client boots, reads token, restores session
    Log.info("browser_navigate_for_token", to: "https://discord.com/404")
    page.goto("https://discord.com/404", waitUntil: "domcontentloaded")
    inject_token_via_evaluate(page)

    Log.info("browser_navigate", to: "https://discord.com/channels/@me")
    page.goto("https://discord.com/channels/@me", waitUntil: "domcontentloaded")

    # Give Discord's SPA a moment to evaluate the token and redirect itself
    sleep 2

    if page.url.to_s.include?("/login")
      $stderr.puts ""
      $stderr.puts "Discord is showing the login page despite cookie/token injection."
      $stderr.puts "Your session in data/discord-cookies.json and DISCORD_TOKEN may be stale."
      $stderr.puts "Re-export from your Mac browser and try again."
      $stderr.puts ""
      $stderr.puts "Alternatively, log in manually via the noVNC web UI:"
      $stderr.puts "  #{NOVNC_URL}"
      $stderr.puts ""
      exit(1)
    end

    [page, context]
  end

  # Reads the Cookie-Editor JSON export and adds the cookies to the Playwright
  # context. Translates field names (expirationDate -> expires, sameSite values
  # to the capitalized form Playwright expects).
  def self.inject_cookies(context)
    return unless File.exist?(COOKIES_PATH)

    raw = JSON.parse(File.read(COOKIES_PATH))
    cookies = raw.map { |c| normalize_cookie(c) }.compact
    return if cookies.empty?

    context.add_cookies(cookies)
    Log.info("cookies_injected", count: cookies.size)
  rescue => e
    Log.warn("cookie_injection_failed", error: e.class, msg: e.message.slice(0, 120))
  end

  # Stores the Discord auth token in localStorage on a page already navigated
  # to the discord.com origin. Discord stores the token wrapped in double
  # quotes (JSON-encoded), so we serialize it the same way.
  #
  # NOTE: Discord aggressively clears localStorage from non-trusted contexts.
  # We work around this by writing via the same trick the DevTools console
  # snippet uses: an iframe whose contentWindow.localStorage is unrestricted.
  def self.inject_token_via_evaluate(page)
    token = ENV["DISCORD_TOKEN"]
    if token.nil? || token.strip.empty?
      Log.warn("token_injection_skipped", reason: "DISCORD_TOKEN not set")
      return
    end

    quoted = JSON.dump(token)

    # Try iframe trick first (most reliable), then direct localStorage as fallback
    page.evaluate(<<~JS)
      (() => {
        try {
          const i = document.createElement('iframe');
          document.body.appendChild(i);
          i.contentWindow.localStorage.setItem('token', #{quoted});
          document.body.removeChild(i);
          return 'iframe';
        } catch (e) {
          try {
            window.localStorage.setItem('token', #{quoted});
            return 'direct';
          } catch (e2) {
            return 'failed: ' + e2.message;
          }
        }
      })();
    JS

    Log.info("token_injected", len: token.length)
  rescue => e
    Log.warn("token_injection_failed", error: e.class, msg: e.message.slice(0, 120))
  end

  SAMESITE_MAP = {
    "no_restriction" => "None",
    "lax"            => "Lax",
    "strict"         => "Strict",
    "unspecified"    => "Lax",
    nil              => "Lax"
  }.freeze

  def self.normalize_cookie(c)
    domain  = c["domain"].to_s.strip
    return nil if domain.empty? || c["name"].nil? || c["value"].nil?

    out = {
      "name"     => c["name"],
      "value"    => c["value"],
      "path"     => c["path"] || "/",
      "secure"   => c["secure"] != false,
      "httpOnly" => c["httpOnly"] == true,
      "sameSite" => SAMESITE_MAP[c["sameSite"]] || "Lax"
    }

    # Playwright wants either domain OR url, not both. Use domain (with leading
    # dot stripped for hostOnly cookies).
    if c["hostOnly"]
      out["domain"] = domain.start_with?(".") ? domain[1..] : domain
    else
      out["domain"] = domain.start_with?(".") ? domain : ".#{domain}"
    end

    # expirationDate is float seconds-since-epoch in Cookie-Editor format;
    # Playwright wants integer seconds in `expires` (or omit for session cookies)
    if c["expirationDate"]
      out["expires"] = c["expirationDate"].to_i
    end

    out
  end
end
