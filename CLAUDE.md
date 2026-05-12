# Discord DM Capture Demo — Build Spec

This document is the build brief for a small Ruby demo that captures Discord DMs to
a local SQLite database. It is intentionally **minimal**: a proof-of-concept to
validate the capture mechanics before any larger system is built around them. Treat
out-of-scope items as out of scope.

---

## Context

The operator runs a sneaker sourcing operation: 70–120 products listed per day on
Discord as "want to buy" posts, with 0–5 inbound DM offers per product from sellers.
Margin per pair is thin (~€4–5), so accurately capturing every offer and matching
sellers' free-text messages to the correct product in a CSV is the long-term goal.

The bigger system (Rails dashboard, AI matching, auto-replies, residential proxy,
multi-day reliability) will be built later. **This demo's only job is to prove the
capture layer works** on a real Discord account, on a fresh test account, running
locally on macOS via Docker. If this demo is reliable for a couple of weeks, the
larger architecture follows. If it is not, the project does not proceed.

## Operator profile

- Comfortable Ruby/Rails developer using mise for version management on macOS.
- Has set up a fresh Discord test account already; not running on a daily-driver.
- Will run Chromium in Docker; Ruby runs natively on the Mac and connects to
  Chromium via the Chrome DevTools Protocol (CDP). This separation is deliberate so
  the operator can edit Ruby with normal local tooling.

## Goal of the demo

A single Ruby script that:

1. Connects to a Chromium browser running in a local Docker container.
2. Hooks the Discord gateway WebSocket and captures every inbound `MESSAGE_CREATE`,
   `MESSAGE_UPDATE`, and `MESSAGE_DELETE` event scoped to direct messages.
3. Persists each event to a local SQLite database with idempotency on
   `discord_message_id`.
4. Prints a single human-readable line to the terminal per captured event.
5. Logs raw frame payloads (compressed or not) so the operator can inspect them and
   learn the real shape of Discord's data.

That is the whole demo. There is no dashboard, no AI, no outbound, no proxy.

## Hard constraints

- **Capture only.** The script must never send messages, click into DMs, or modify
  read state. It is a passive observer.
- **Read-state preservation.** Do not navigate into DM conversations. Listen on the
  WebSocket, do not scrape the DOM. If the operator opens Discord on their phone,
  unread badges must remain accurate.
- **Idempotency.** `discord_message_id` is a unique key. The script must be
  restartable without producing duplicate rows.
- **No DOM scraping for message content.** Selectors break; WebSocket frames don't.
- **Local-only.** Bind all ports to `127.0.0.1`. Do not expose anything to the
  network during the demo.

## Out of scope (do not build)

- Sending messages or any UI interaction beyond the initial login the operator does
  manually.
- Residential proxy configuration. Operator's home IP is fine for the demo.
- CSV matching or any AI calls.
- A web dashboard or HTTP server of any kind.
- Multi-account support.
- Postgres, Rails, Sidekiq, Redis, Action Cable, or any of that. Plain Ruby script
  - SQLite.
- Captcha auto-solving. If login captcha appears, operator solves it manually in
  the noVNC view.
- Reconnection backfill (pulling missed messages after gateway reconnect). Note the
  gap but do not implement recovery in v1.

## Tech stack

- Ruby 3.2 or newer (operator has mise).
- `playwright-ruby-client` to drive Chromium over CDP.
- `sqlite3` gem for storage.
- `dotenv` for config.
- Chromium in Docker via `lscr.io/linuxserver/chromium` (has built-in noVNC web UI
  for the initial manual login).
- macOS host, Docker Desktop.

## File layout

```
discord-demo/
├── docker-compose.yml      # Chromium container with CDP + noVNC
├── Gemfile
├── .env.example
├── .env                    # gitignored, operator creates from example
├── .gitignore
├── README.md               # operator-facing setup + run instructions
├── bin/
│   ├── setup               # install gems, prepare data dir, pull docker image
│   ├── chromium-up         # docker compose up -d + print noVNC URL
│   ├── chromium-down       # docker compose down
│   └── inspect             # quick SQLite query helper
├── src/
│   ├── capture.rb          # main entry point: starts the listener
│   ├── db.rb               # SQLite setup, schema, insert helpers
│   ├── browser.rb          # CDP connection helper via playwright-ruby-client
│   ├── gateway.rb          # WebSocket frame hook and dispatch
│   └── logger.rb           # tiny structured logger
└── data/
    ├── chromium-profile/   # persistent Chromium user data dir (gitignored)
    ├── messages.sqlite3    # the capture DB (gitignored)
    └── raw-frames/         # JSONL files, one per day, raw frames (gitignored)
```

## docker-compose.yml

The compose file uses `lscr.io/linuxserver/chromium` which ships with noVNC. CDP
must be enabled and bound to `0.0.0.0` inside the container so the Ruby script on
the Mac can reach it.

```yaml
services:
  chromium:
    image: lscr.io/linuxserver/chromium:latest
    container_name: discord-demo-chromium
    security_opt:
      - seccomp:unconfined
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Madrid
      - CUSTOM_USER=admin
      - PASSWORD=${CHROMIUM_PASSWORD:-changeme}
      - CHROME_CLI=--remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 --disable-features=WebRtcHideLocalIpsWithMdns --force-webrtc-ip-handling-policy=disable_non_proxied_udp --disable-blink-features=AutomationControlled
    volumes:
      - ./data/chromium-profile:/config
    ports:
      - "127.0.0.1:3010:3000" # noVNC web UI (http)
      - "127.0.0.1:3011:3001" # noVNC web UI (https)
      - "127.0.0.1:9222:9222" # CDP
    shm_size: 2gb
    restart: unless-stopped
```

Note: `linuxserver/chromium` versions vary in how they accept Chrome flags; if
`CHROME_CLI` does not propagate to the runtime in the version pulled, fall back to
mounting a `chromium-flags.conf` into `/config/.config/chromium-flags.conf` with the
same flags one per line. Verify CDP is reachable from the host with `curl
http://localhost:9222/json/version` after starting the container.

### Why the AutomationControlled flag

`--disable-blink-features=AutomationControlled` masks the most common automation
fingerprint. The demo is not trying hard to defeat detection — that's a later
concern with proxy and stealth plugin — but this one flag is free and prevents the
`navigator.webdriver` flag from broadcasting "this is a bot." Reasonable default.

## Database schema

SQLite, one file at `./data/messages.sqlite3`.

```sql
CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  discord_message_id TEXT NOT NULL UNIQUE,
  discord_channel_id TEXT NOT NULL,
  discord_author_id TEXT NOT NULL,
  author_username TEXT,
  author_display_name TEXT,
  event_type TEXT NOT NULL,          -- MESSAGE_CREATE | MESSAGE_UPDATE | MESSAGE_DELETE
  content TEXT,
  timestamp_iso TEXT,                -- from payload, ISO8601
  is_dm INTEGER NOT NULL,            -- 1 if guild_id is null
  raw_payload TEXT NOT NULL,         -- full JSON of the event data
  captured_at TEXT NOT NULL,         -- ISO8601 of when we wrote the row
  CHECK (event_type IN ('MESSAGE_CREATE', 'MESSAGE_UPDATE', 'MESSAGE_DELETE'))
);

CREATE INDEX IF NOT EXISTS idx_messages_channel ON messages (discord_channel_id);
CREATE INDEX IF NOT EXISTS idx_messages_author ON messages (discord_author_id);
CREATE INDEX IF NOT EXISTS idx_messages_captured ON messages (captured_at);

CREATE TABLE IF NOT EXISTS session_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event TEXT NOT NULL,               -- gateway_open | gateway_close | reconnect | error | heartbeat
  detail TEXT,
  occurred_at TEXT NOT NULL
);
```

`raw_payload` is the full Discord event payload (the `d` field of the gateway
frame). Keep everything — attachments, embeds, reply references — for inspection
later. This is the _whole point_ of the demo: see the real shape of the data.

`MESSAGE_UPDATE` and `MESSAGE_DELETE` events should be inserted as new rows, not
mutations of existing rows. Two reasons: we want history, and `MESSAGE_DELETE`
payloads don't include the original content. Use `INSERT OR IGNORE` keyed on a
composite of `(discord_message_id, event_type, captured_at)` if true uniqueness is
needed; for v1, a simple insert is fine and the operator can dedupe at query time.

Actually — revise that. Make the unique constraint `(discord_message_id,
event_type)` instead of `discord_message_id` alone. That preserves idempotency
per-event-type and lets all three event types coexist for the same message.

```sql
CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  discord_message_id TEXT NOT NULL,
  discord_channel_id TEXT NOT NULL,
  discord_author_id TEXT,
  author_username TEXT,
  author_display_name TEXT,
  event_type TEXT NOT NULL,
  content TEXT,
  timestamp_iso TEXT,
  is_dm INTEGER NOT NULL,
  raw_payload TEXT NOT NULL,
  captured_at TEXT NOT NULL,
  UNIQUE (discord_message_id, event_type)
);
```

`discord_author_id` is nullable because `MESSAGE_DELETE` payloads sometimes don't
include the author.

## Gateway WebSocket capture — the core mechanism

This is the critical piece. Discord's web client maintains a WebSocket to
`wss://gateway.discord.gg/?...` and receives every event as a JSON frame. Playwright
exposes a `framereceived` event on WebSocket objects, which fires for every
incoming frame.

Pseudocode for the listener:

```ruby
require "playwright"
require "json"
require "zlib"

Playwright.create(playwright_cli_executable_path: "playwright") do |pw|
  browser = pw.chromium.connect_over_cdp(ENV.fetch("CHROMIUM_CDP_URL"))
  context = browser.contexts.first || browser.new_context
  page = context.pages.first || context.new_page

  page.goto("https://discord.com/channels/@me") unless page.url.start_with?("https://discord.com")

  page.on("websocket", lambda do |ws|
    next unless ws.url.include?("gateway")
    Logger.info("gateway_open", url: ws.url)
    DB.record_session_event("gateway_open", ws.url)

    ws.on("framereceived", lambda do |payload|
      Gateway.handle_frame(payload)
    end)

    ws.on("close", lambda do
      Logger.warn("gateway_close")
      DB.record_session_event("gateway_close", nil)
    end)
  end)

  # heartbeat loop so the script stays alive and we can log liveness
  loop do
    DB.record_session_event("heartbeat", nil)
    sleep 30
  end
end
```

### Compressed frames

Discord's gateway _can_ send zlib-compressed frames depending on the connect
parameters the client uses. The web client typically negotiates `compress=zlib-stream`,
which means frames arrive as a zlib stream that needs incremental decompression with
a _single shared inflater per connection_ — not per-frame.

For the demo, handle this:

1. Try to parse the frame as JSON directly. If it parses, use it.
2. If it doesn't parse, write the raw bytes to `data/raw-frames/YYYY-MM-DD.bin`
   prefixed with a 4-byte length so the operator can inspect them with a separate
   script later.
3. Also try `Zlib::Inflate.new` with a persistent inflater across frames on each
   WebSocket. Log whether it worked.

The point of the demo is to _find out_ what your specific session sends. Don't over-
engineer; capture both possibilities, log what happens, and look at the data after a
day of capture to decide the production approach.

### Event filtering

We only care about `MESSAGE_CREATE`, `MESSAGE_UPDATE`, `MESSAGE_DELETE`. The frame
schema is:

```json
{ "op": 0, "t": "MESSAGE_CREATE", "s": 12345, "d": { ... event data ... } }
```

Filter on `t`. Anything else is logged at debug level only (or not at all in v1) to
keep the terminal readable.

Check `d.guild_id`:

- `null` or absent → this is a DM. Set `is_dm = 1`.
- present → this is a guild message. Set `is_dm = 0`.

Capture both, but the operator's interest is DMs. The terminal printer should only
print DMs at info level; guild messages go to debug.

## Module breakdown

### `src/db.rb`

- Initializes the SQLite DB on first run (creates tables and indexes).
- Public methods:
  - `DB.insert_event(event_type:, payload:)` — extracts fields, inserts row.
    Uses `INSERT OR IGNORE` on the unique constraint.
  - `DB.record_session_event(event, detail)` — for gateway open/close, errors, heartbeats.
  - `DB.connection` — returns the SQLite3::Database, opened with
    `results_as_hash: true` and `WAL` journal mode for concurrent reads.

### `src/browser.rb`

- `Browser.connect` — wraps the `playwright.chromium.connect_over_cdp` call,
  returns the page object, ensures Discord is loaded.
- Handles the case where no context/page exists yet.
- If the page is on the login screen (`/login` in URL), prints a clear message
  pointing the operator at the noVNC URL and exits with a non-zero status.

### `src/gateway.rb`

- `Gateway.handle_frame(payload)` — entry point from the Playwright callback.
- Tries JSON parse. If fail, writes raw to `data/raw-frames/...` and attempts
  zlib decompression.
- On success, dispatches `MESSAGE_*` events to `DB.insert_event` and prints to
  terminal via `Logger`.

### `src/logger.rb`

- Tiny wrapper. Two methods: `Logger.info(event, **attrs)` and
  `Logger.warn(event, **attrs)`. Output as `[ISO8601] [LEVEL] event key=value
key=value`. No external dependency.

### `src/capture.rb`

- The main entry point. Loads `.env`, sets up DB, connects browser, registers
  WebSocket handlers, sits in the heartbeat loop.
- Traps `INT` and `TERM` for clean shutdown.
- Wraps the main loop in a top-level rescue that logs and re-raises so the
  operator sees what killed the script.

## bin/ scripts

### `bin/setup`

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p data/chromium-profile data/raw-frames
[ -f .env ] || cp .env.example .env
bundle install
docker compose pull
echo "Setup complete. Edit .env if needed, then run bin/chromium-up."
```

### `bin/chromium-up`

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose up -d
echo "Chromium starting..."
sleep 3
echo "noVNC web UI: http://localhost:3010 (user: admin, password from .env)"
echo "CDP endpoint: http://localhost:9222"
echo ""
echo "Next steps:"
echo "  1. Open the noVNC URL in your browser."
echo "  2. Navigate to https://discord.com/login and log in to your test account."
echo "  3. Once you see your DM list, close the browser tab in noVNC (do NOT shut down Chromium)."
echo "  4. Run: bundle exec ruby src/capture.rb"
```

### `bin/chromium-down`

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose down
```

### `bin/inspect`

Quick CLI to look at what's been captured:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
DB="${DB_PATH:-./data/messages.sqlite3}"
echo "=== Counts by event type ==="
sqlite3 -header -column "$DB" "SELECT event_type, COUNT(*) FROM messages GROUP BY event_type;"
echo ""
echo "=== Last 10 DM messages ==="
sqlite3 -header -column "$DB" "SELECT captured_at, author_username, substr(content, 1, 60) AS preview FROM messages WHERE is_dm=1 AND event_type='MESSAGE_CREATE' ORDER BY id DESC LIMIT 10;"
echo ""
echo "=== Session events (last 20) ==="
sqlite3 -header -column "$DB" "SELECT occurred_at, event, detail FROM session_events ORDER BY id DESC LIMIT 20;"
```

## .gitignore

```
.env
data/
*.log
.bundle/
vendor/
```

## README.md content

The README should be operator-facing and answer: how do I run this, how do I log
in, how do I inspect the data, what should I look at, how do I stop it. Concrete
steps for macOS + mise + Docker Desktop. Include the gotchas section below as
"What to watch for" so the operator knows what they're looking for in the data.

## What the operator will look for (validation checklist)

After 24–48 hours of running, the operator should be able to answer all of these
from the SQLite data and raw frame logs:

1. **Were frames JSON or zlib-compressed?** Inspect `data/raw-frames/`. If files
   are empty, frames parsed as JSON directly. If files have content, zlib was used.
2. **Did every DM I received get captured?** Have a friend (or yourself from
   another account) send a known sequence of test messages and verify they all
   appear with the right `discord_message_id`.
3. **How often did the gateway reconnect?** Query `session_events` for
   `gateway_close` entries. Multiple per hour is a problem; once or twice a day
   is normal.
4. **What event types arrived besides messages?** Add a debug log of any frame
   with `t` not in the known set, to discover events worth handling later.
5. **Did edits and deletes flow through?** Edit a test message; delete a test
   message; confirm both arrive as separate rows.
6. **What does a real seller-style DM look like in the database?** Pull a sample
   row and look at `raw_payload`. This is what the parser/matcher will operate on
   later.
7. **Did the script stay up?** Check process uptime and the gap between the
   newest `heartbeat` event in `session_events` and now. Crashes or freezes are
   the most important data point from the demo.

## Acceptance criteria

The demo is considered successful if, after 7 days of running:

- 100% of test messages sent to the account from a known sender ID are present in
  `messages` with the correct content.
- The script process did not crash more than once (one crash from an unexpected
  edge case is acceptable and logged; repeated crashes indicate the approach
  doesn't work).
- Gateway reconnects were handled without operator intervention (Playwright's
  WebSocket hook reattached on reconnect, or a known reconnect-handling gap is
  documented).
- The operator can answer the validation checklist questions above from the
  captured data.

If those criteria are met, the larger system build is justified. If not, the
findings inform whether to pivot approach (e.g., DOM observer instead of
WebSocket, or running Discord client directly under Electron, or abandoning
headless entirely and building the legitimate server-bot funnel).

## Notes on dependencies and environment

- `playwright-ruby-client` requires the Playwright Node CLI to be installed. The
  gem documents how to install it; usually `npm install -g playwright` and then
  the gem finds the binary via `PATH`. Document this in the README. macOS with
  mise users: install Node via mise too, then `npm i -g playwright`.
- Pin gem versions in the Gemfile to known-working majors. Avoid floating versions
  on a project that needs to survive Discord-side changes; the Ruby side should be
  stable.
- The persisted Chromium profile in `data/chromium-profile/` is the auth cookie
  store. Deleting it means re-logging in. Back it up after first successful login.

## What the operator should NOT do during the demo

- Do not configure a proxy. Run on your home IP.
- Do not turn the script into a daemon yet. Run it in a terminal you can watch.
  Stability observations are part of the demo's value.
- Do not start adding the CSV matching or AI calls. Resist the urge. Capture first,
  interpret later.
- Do not connect their daily-driver account "just to test." If the demo proves
  capture works on the test account, the daily-driver migration is a separate
  decision made later with proxy and additional precautions.

## Handoff

Build the files exactly as specified. Ask the operator for clarification only on
ambiguities not covered here. Where this document is silent, prefer the simplest
implementation that satisfies the acceptance criteria.
