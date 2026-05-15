# Discord DM Capture — Chrome MV3 extension

A Chrome MV3 extension that hooks Discord's gateway WebSocket from inside the
operator's own Chrome (where Discord is already legitimately logged in) and
mirrors inbound DMs to a Rails ingestion endpoint over HTTPS. It also surfaces
a **live side panel** so you can watch frames arrive in real time.

Replaces the demo's Playwright-in-Docker capture path. No captcha exposure,
no Docker, no proxy — Discord just sees the operator's normal browser.

## Files

```
extension/
├── manifest.json
├── inject.js               # MAIN world: hooks window.WebSocket
├── inject.bundle.js        # built: pako + inject.js (loaded by manifest)
├── content.js              # ISOLATED world: bridge to service worker
├── background.js           # service worker: queue, ingest POST, long-poll, broadcast
├── sidepanel.html / .js / .css   # live feed + diagnostics
├── vendor/pako_inflate.min.js     # zlib decompression
├── icons/{16,48,128}.png
├── build.sh                # rebuilds inject.bundle.js
└── README.md
```

## Build

After editing `inject.js`, rebuild:

```sh
./build.sh
```

(Concatenates `vendor/pako_inflate.min.js + inject.js` → `inject.bundle.js`,
which is what the manifest loads. Files other than `inject.js` are loaded
directly and don't need a build step.)

## Install (unpacked)

1. Open `chrome://extensions` in Chrome.
2. Turn on **Developer mode** (top right).
3. Click **Load unpacked** and select this `extension/` directory.
4. The "Discord DM Capture" card appears.

To reload after a code change: hit the reload icon on the extension's card,
then refresh any open Discord tab so `inject.js` re-runs at `document_start`.

## First-run smoke test (no Rails needed)

1. Click the extension icon in the toolbar.
2. The **side panel** opens on the right. The top bar shows status; the main
   area will become a scrolling feed of gateway frames.
3. Open `https://discord.com/channels/@me` in a new tab. (Same Chrome
   profile; you should already be logged in.)
4. Within ~3 seconds the connection dot at the top of the side panel goes
   green, and you'll see lines like `gateway_open`, then `READY` summary,
   then real frames as Discord traffic flows.
5. Send yourself a DM. A `MESSAGE_CREATE` line appears with the author and
   the first chunk of content.

At this point capture is working end-to-end up to the service worker. No
Rails yet means nothing's being persisted — the side panel is your view.

The status row at the top shows:

- **GW** — number of open gateway WebSockets
- **F**  — total frames seen
- **Q**  — queue depth waiting for Rails
- **↑**  — successful Rails flushes
- last-frame age — time since the most recent frame

Filters at the top of the feed:

- **DM only** — hide non-DM messages (guild traffic, etc.)
- **Captured only** — hide events that don't match the dispatch filter
  (heartbeats, presence, typing). Useful for confirming only the events
  we care about flow through to the dispatcher.
- **Pause** — stop adding new lines; existing feed stays visible
- **Clear** — empty the feed and the SW's recent-events ring buffer

## Wiring to Rails

Open the **Config & diagnostics** section at the bottom of the side panel:

1. Paste your `capture_api_key` from Rails credentials → click **Save**.
2. The ingest URL is **hard-coded** in `background.js`
   (`http://localhost:3000/capture/ingest` by default). To change it, edit
   the constants at the top of that file and reload the extension.
3. Click **Self-test ingest** — POSTs a synthetic `gateway_session` event
   to Rails without touching the WebSocket hook. Confirms the URL + auth.
4. Click **Hook test** — round-trips a synthetic `MESSAGE_CREATE` through
   MAIN → bridge → SW. The synthetic frame appears in the feed (tinted)
   even though it never came from Discord. Run this daily to confirm
   the hook is still working after any Discord frontend update.
5. Click **Flush now** — drains the queue immediately.

## Diagnostics console

For verbose internals, open the SW console:

```
chrome://extensions → Discord DM Capture card → "Service worker"
```

Shows `[capture] flush_ok`, `[capture] flush_failed`, port connects/
disconnects, command-loop status, etc.

## Failure recovery

MV3 service workers are killed after ~30s of idleness. Defenses:

- The content-script port keeps the SW alive while a Discord tab is open.
- The side panel itself, when open, also keeps the SW alive via its own port.
- The port is cycled every 4 minutes to dodge Chrome's 5-minute port-lifetime cap.
- `chrome.alarms` wakes the SW every 60 seconds as belt-and-braces.
- Queue persists to `chrome.storage.local` on every flush failure; SW
  restart reloads it and retries.
- Exponential backoff on POST failures: 2s, 5s, 15s, 60s, 5min, capped.

If Rails is down for hours, the queue grows up to 5000 entries (capped).
On overflow the oldest are dropped and a `queue_overflow` session event is
logged.

## Operational requirements

- Chrome **111+** (static `world: MAIN` content scripts) and **114+** (side
  panel API).
- Discord tab open in this Chrome profile, already logged in.
- Chrome process running. Tab can be minimized/in-background/pinned, just
  not closed. **Pinning the Discord tab is recommended** — Chrome's tab
  freezer skips pinned tabs.
- Home PC awake (OS not asleep).
- Rails ingestion endpoint reachable at the URL hard-coded in
  `background.js` (only required if you want frames persisted; capture
  works fine without it for visual verification).

## Not in v1

- Outbound `send()` capture (we don't mirror what your own client sends
  except when relaying an ACK command from Rails).
- Multi-account capture (one Chrome profile, one Discord login).
- Discord REST API calls for backfill (explicitly avoided).
- Web Store distribution (loaded unpacked).
- Cross-browser support (Chrome only).

## Updating the ACK opcode

The `dispatchCommand` function in `background.js` builds outbound ACK frames
using a **placeholder** shape: `{op: 3, d: {channel_id, message_id}}`. The
real shape needs to be confirmed by observing one with the side panel's feed
once you can interact with a logged-in account.

To capture it:

1. Open Discord DevTools → Network → click the gateway WS connection.
2. Open a DM in another window/tab so the desktop client sees it.
3. Watch the **Frames** tab; mark the message as read on your phone, then
   on the desktop the *next outbound frame* should be the ACK.
4. Update `dispatchCommand` to match the captured shape and reload the
   extension.

Until then, ACK commands from Rails will be sent with the placeholder shape
and Discord will probably ignore them. No risk to the account.
