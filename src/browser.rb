# frozen_string_literal: true

require "playwright"
require_relative "logger"

module Browser
  NOVNC_URL = "http://localhost:3010"

  def self.connect(playwright_instance)
    cdp_url = ENV.fetch("CHROMIUM_CDP_URL", "http://localhost:9222")

    Log.info("browser_connect", cdp_url: cdp_url)
    browser = playwright_instance.chromium.connect_over_cdp(cdp_url)

    context = browser.contexts.first || browser.new_context
    page    = context.pages.first    || context.new_page

    current_url = page.url.to_s

    if current_url.include?("/login")
      $stderr.puts ""
      $stderr.puts "Discord is showing the login page."
      $stderr.puts "Please log in manually via the noVNC web UI:"
      $stderr.puts "  #{NOVNC_URL}"
      $stderr.puts ""
      $stderr.puts "Once logged in and your DM list is visible, re-run this script."
      $stderr.puts ""
      exit(1)
    end

    unless current_url.start_with?("https://discord.com")
      Log.info("browser_navigate", to: "https://discord.com/channels/@me")
      page.goto("https://discord.com/channels/@me", waitUntil: "domcontentloaded")
    end

    page
  end
end
