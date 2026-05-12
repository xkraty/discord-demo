# Discord DM Capture Demo

Passively captures Discord DMs to a local SQLite database via Discord's gateway
WebSocket. No messages are sent, no DMs are opened, read state is preserved.

---

## Prerequisites

- macOS with [mise](https://mise.jdx.dev/) installed
- Ruby ≥ 3.2 via mise: `mise use ruby@latest`
- Node.js via mise (needed for Playwright CLI): `mise use node@lts`
- Docker Desktop running

---

## First-time setup

```bash
bin/setup
```

This will:
- Create `data/` directories
- Copy `.env.example` → `.env`
- Run `bundle install`
- Install the Playwright CLI (`npm install -g playwright`) if missing
- Pull the Chromium Docker image

Edit `.env` if you want a custom noVNC password:
```
CHROMIUM_CDP_URL=http://localhost:9223
CHROMIUM_PASSWORD=changeme
```

---

## Login

Start Chromium in Docker:

```bash
bin/chromium-up
```

Then:

1. Open **http://localhost:3010** in your browser (noVNC web UI)
2. Navigate to **https://discord.com/login** inside noVNC
3. Log in to your **test account** (not your daily driver)
4. Wait until your DM list is visible
5. Leave Chromium running — do not close the container

Your session is persisted in `data/chromium-profile/`. Back this directory up after
a successful first login so you don't have to log in again if you reset Docker.

---

## Running the capture

```bash
bundle exec ruby src/capture.rb
```

Normal startup output:

```
[2026-05-12T10:00:00Z] [INFO] capture_start
[2026-05-12T10:00:01Z] [INFO] browser_connect cdp_url=http://localhost:9223
[2026-05-12T10:00:02Z] [INFO] browser_ready url=https://discord.com/channels/@me
[2026-05-12T10:00:02Z] [INFO] browser_reload reason=reattach_gateway_ws
[2026-05-12T10:00:04Z] [INFO] gateway_open url=wss://gateway.discord.gg/...
[2026-05-12T10:00:04Z] [INFO] listening note=waiting_for_gateway_frames
[2026-05-12T10:00:34Z] [INFO] heartbeat
```

When a DM arrives:

```
[2026-05-12T10:01:05Z] [INFO] MESSAGE_CREATE message_id=... channel_id=... author=alice preview="hey got a pair for you"
```

Stop with **Ctrl-C**. The script traps `INT`/`TERM` and shuts down cleanly.

---

## Inspecting captured data

```bash
bin/inspect
```

Or query directly:

```bash
# All captured DMs
sqlite3 -header -column data/messages.sqlite3 \
  "SELECT captured_at, author_username, content FROM messages WHERE is_dm=1 ORDER BY id DESC LIMIT 20;"

# Raw payload for a specific message
sqlite3 data/messages.sqlite3 \
  "SELECT raw_payload FROM messages WHERE discord_message_id='<id>';"

# Gateway reconnect count
sqlite3 data/messages.sqlite3 \
  "SELECT COUNT(*) FROM session_events WHERE event='gateway_close';"
```

---

## Stopping

```bash
# Stop capture script
Ctrl-C

# Stop Chromium container (login session is preserved in data/chromium-profile/)
bin/chromium-down
```

---

## Troubleshooting

**CDP not reachable (`browser_connect` hangs or errors)**

```bash
curl http://localhost:9223/json/version
```

Should return a JSON blob with `webSocketDebuggerUrl`. If you get "Empty reply from
server" or a hang, check both containers are up:

```bash
docker ps --filter name=discord-demo
```

You should see `discord-demo-chromium` and `discord-demo-cdp-proxy` both running.
The proxy container shares Chromium's network namespace and forwards traffic from
`9223` to Chromium's `127.0.0.1:9222` (Chromium ignores
`--remote-debugging-address=0.0.0.0` in this image build and only listens on
loopback inside the container, which is why the proxy is necessary). Check the
proxy logs:

```bash
docker logs discord-demo-cdp-proxy
```

If Chromium itself isn't responding, inspect from inside the container:

```bash
docker exec discord-demo-chromium curl -s http://localhost:9222/json/version
```

If that returns nothing, Chromium hasn't started yet — wait 10 seconds and retry,
or check `docker logs discord-demo-chromium`.

**Discord shows login page every time**

The session cookie in `data/chromium-profile/` may be expired or corrupted. Delete
the directory, re-run `bin/chromium-up`, and log in again:

```bash
rm -rf data/chromium-profile
bin/chromium-up
```

**Frames going to `data/raw-frames/` instead of the database**

Discord sent zlib-compressed frames. The capture script attempts decompression; if
it fails, raw bytes land in `data/raw-frames/YYYY-MM-DD.bin`. Check the `WARN`
lines in the terminal for `frame_decompress_failed`. The first two bytes of a frame
identify the codec: `0x78 0x9C` = zlib (handled), `0x1F 0x8B` = gzip (not yet
handled), anything else = raw deflate. File an issue or extend `gateway.rb`
accordingly.

**`playwright CLI not found` or Playwright errors at startup**

```bash
npm install -g playwright
```

If using mise for Node, ensure shims are active: `mise reshim`. You can also set the
path explicitly in `src/capture.rb`:

```ruby
playwright_cli_executable_path: "#{ENV['HOME']}/.local/share/mise/installs/node/lts/bin/playwright"
```

**No `gateway_open` log after startup**

The page reload should force a new gateway connection. If you still don't see it
within 10 seconds, manually reload Discord inside the noVNC browser — this triggers
a new WebSocket that the listener will catch.

---

## What to watch for (validation checklist)

After 24–48 hours, check these from the SQLite data and `data/raw-frames/`:

1. **JSON or zlib?** If `data/raw-frames/` files are empty, frames parsed as JSON
   directly. If they have content, zlib was used (check `WARN` logs).
2. **Every DM captured?** Have a friend send a known sequence. Verify all appear
   with the correct `discord_message_id`.
3. **Gateway reconnects?** `SELECT COUNT(*) FROM session_events WHERE event='gateway_close';`
   Multiple per hour is a problem; once or twice a day is normal.
4. **Other event types?** Add debug logging in `gateway.rb` `dispatch` for `t`
   values outside the known set to discover events worth handling later.
5. **Edits and deletes?** Edit and delete a test message; confirm both appear as
   separate rows (`MESSAGE_UPDATE`, `MESSAGE_DELETE`).
6. **Real message shape?** Pull a sample row: `SELECT raw_payload FROM messages LIMIT 1;`
   This is the payload the future parser will operate on.
7. **Script uptime?** Check the gap between the most recent `heartbeat` in
   `session_events` and now. A large gap means the script crashed or froze.

---

## Architecture notes

- **Why CDP instead of a bot token?** The operator's use case involves a user
  account, not a bot. Discord's gateway events for user accounts are only accessible
  via the web client's WebSocket.
- **Why WebSocket hooks instead of DOM scraping?** Selectors change with Discord
  deploys; WebSocket frames are stable. DOM scraping would also require navigating
  into DMs, which would mark them as read.
- **Why SQLite?** Single-file, zero infrastructure, trivially inspectable with the
  `sqlite3` CLI. Plenty fast for the demo's write rate.
- **Why a page reload at startup?** Playwright's `page.on("websocket")` only fires
  for WebSockets opened after the listener is registered. Discord's gateway
  connection is already open when the script attaches. The reload forces a reconnect
  that fires the listener. This adds ~2 seconds to startup.
- **Why the `cdp-proxy` sidecar container?** The `lscr.io/linuxserver/chromium`
  image builds Chromium in a way that ignores `--remote-debugging-address=0.0.0.0`
  and binds the CDP server to `127.0.0.1` inside the container. Docker port
  forwarding hits the container's `eth0`, which Chromium isn't listening on, so
  CDP connections from the host fail. The sidecar shares Chromium's network
  namespace (`network_mode: "service:chromium"`) and forwards `0.0.0.0:9223` →
  `127.0.0.1:9222`, giving the host a reachable CDP endpoint without changing
  Chromium's flags.
