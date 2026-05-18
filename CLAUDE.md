# Discord DM Capture — project spec

## What this is

A Rails 8 app that ingests Discord gateway events from a Chrome MV3
extension and shows a real-time DM feed.

The extension hooks the operator's normal Chrome session (where Discord
is already logged in), mirrors every gateway frame it sees, and POSTs
batches to this Rails app over HTTPS. The Rails app persists each event
to Postgres and broadcasts new DMs to the dashboard via Turbo Streams
over Solid Cable.

This replaces an earlier Playwright-in-Docker capture demo that hit a
wall on production Discord accounts (anti-bot captchas in a datacenter
Chromium). The extension approach uses the operator's legitimate
session and IP, so Discord sees a normal user with no automation signals.

## Architecture

```
┌────────────────────────┐        HTTPS         ┌────────────────────────────┐
│ Operator's Chrome      │   POST /capture/     │ Rails 8 on Kamal VPS       │
│ (always-on home PC)    │ ──ingest──────────▶  │                            │
│                        │   Bearer auth        │  ┌──────────────────────┐  │
│ ┌────────────────────┐ │                      │  │ Capture::Ingest      │  │
│ │ MV3 extension      │ │                      │  │ Controller           │  │
│ │ - WebSocket hook   │ │                      │  └─────────┬────────────┘  │
│ │ - pako decompress  │ │                      │            │                │
│ │ - side panel       │ │                      │  ┌─────────▼────────────┐  │
│ │ - SW queue+retry   │ │                      │  │ CaptureIngestService │  │
│ └────────────────────┘ │                      │  └─────────┬────────────┘  │
└────────────────────────┘                      │            │                │
                                                │  ┌─────────▼────────────┐  │
        ┌────────────────────────────────────┐  │  │ Postgres             │  │
        │ Operator's browser (any device)    │◀─┼──┤ + Solid Trifecta DBs │  │
        │ Dashboard at /                     │  │  └──────────────────────┘  │
        │ Turbo Streams over Solid Cable     │  │            │                │
        └────────────────────────────────────┘  │  ┌─────────▼────────────┐  │
                                                │  │ DashboardController  │  │
                                                │  │ (basic auth)         │  │
                                                │  └──────────────────────┘  │
                                                └────────────────────────────┘
```

## Stack

- Rails 8.1 + Hotwire (Turbo + Stimulus)
- Tailwind CSS + importmap (no Node build step)
- Solid Queue / Solid Cache / Solid Cable — no Redis
- Postgres (primary DB + three side DBs for the Solid trifecta)
- Kamal 2 for deploy → single VPS, ghcr.io image, postgres accessory
- Thruster + Puma at runtime
- HTTP Basic auth for the dashboard, Bearer for the ingest endpoint

## Repo layout

```
discord-demo/
├── app/                        Rails app (controllers, models, views, services)
├── bin/, config/, db/, …       standard Rails 8
├── extension/                  Chrome MV3 extension (separate concern)
│   ├── manifest.json
│   ├── background.js           service worker: queue, batching, POST to Rails
│   ├── content.js              ISOLATED-world bridge
│   ├── inject.js               MAIN-world WebSocket hook
│   ├── inject.bundle.js        built: pako + inject.js
│   ├── sidepanel.{html,js,css} live frame feed UI
│   └── vendor/pako*.js
├── PRODUCTION_PLAN.md          longer-horizon roadmap (matcher, CSV, etc.)
├── CLAUDE.md                   this file
└── README.md                   operator runbook (local dev + deploy)
```

## Wire format

The extension batches captured events and POSTs them to `/capture/ingest`:

```http
POST /capture/ingest HTTP/1.1
Authorization: Bearer <Rails.application.credentials.capture_api_key>
Content-Type: application/json
X-Batch-Id: <uuid>

{
  "batch_id": "uuid",
  "client": {"extension_version": "0.1.0", "profile_id": "stable-uuid"},
  "events": [
    {"kind": "gateway_frame", "ws_id": 3, "received_at": "ISO8601",
     "frame": {"op": 0, "t": "MESSAGE_CREATE", "s": 42, "d": { … }}},
    {"kind": "gateway_session", "event": "gateway_open", "ws_id": 3,
     "detail": "wss://…", "occurred_at": "ISO8601"}
  ]
}
```

Response:

```json
{"ok": true, "accepted": 1, "failed": 0, "batch_id": "uuid"}
```

`CaptureIngestService` routes by event kind:

| kind | Frame `t` | What we do |
|---|---|---|
| `gateway_frame` | `MESSAGE_CREATE/UPDATE/DELETE` | `DiscordMessage.create!` (rescue RecordNotUnique) |
| `gateway_frame` | `CHANNEL_CREATE` | synthetic message row + `Channel.upsert_from_payload` |
| `gateway_frame` | `MESSAGE_ACK` | `ChannelReadState.upsert` (only if version > stored) |
| `gateway_frame` | other (`READY`, presence, …) | `DiscordSessionEvent` with a small JSON summary |
| `gateway_session` | — | `DiscordSessionEvent` (gateway_open/close/error/decompress_error) |
| `gateway_raw` | — | `DiscordSessionEvent("raw_frame")` for diagnostics |

Idempotency is enforced at the DB level by
`UNIQUE(discord_message_id, event_type)`. Retried batches are safe.

## Auth model

**Bearer (extension → Rails)** — `Authorization: Bearer <capture_api_key>`,
where the key is in `Rails.application.credentials.capture_api_key`. Used
only on `POST /capture/ingest`. Implemented in
`Capture::IngestController#authenticate_bearer!` via `secure_compare`.

**HTTP Basic (operator → dashboard)** — username + password in
`Rails.application.credentials.basic_auth.{user,pass}`. Applied as a
`before_action :authenticate_dashboard!` in `DashboardController`. Not
global — `Capture::IngestController` inherits from `ActionController::API`
and is unaffected.

## Models

- **DiscordMessage** — every captured gateway frame we care about. Scope
  `.dms` filters to inbound DMs. `after_create_commit` broadcasts new
  inbound `MESSAGE_CREATE` rows to the `dms` Turbo Streams channel.
- **DiscordSessionEvent** — gateway open/close/error, READY summaries,
  raw-frame fallbacks. Scope `.recent` orders by `occurred_at` desc.
- **Channel** — channel metadata for label lookups.
  `Channel.upsert_from_payload(hash)` derives a name from DM recipients,
  group DM members, or guild channel name+type.
- **ChannelReadState** — per-channel last-read tracker, populated by
  `MESSAGE_ACK` events. Used in the future for the dashboard "is this
  already read on my phone?" indicator.
- **AckRequest** — schema only. Will be the queue Rails fills when an
  operator clicks "mark read" in the dashboard; the extension's
  long-poll will drain it. No controller yet.

## Realtime

`DiscordMessage` has `after_create_commit :broadcast_to_feed` (guarded by
`is_dm && event_type == "MESSAGE_CREATE"`) that calls
`broadcast_prepend_to "dms", target: "feed", partial: …`. The dashboard
view subscribes via `<%= turbo_stream_from "dms" %>`.

In **development** the Action Cable adapter is `async` (in-process only),
so two browser tabs sharing the same Puma will receive broadcasts. In
**production** it's `solid_cable`, which persists messages via the cable
database for delivery across processes.

## Local development

See [README.md](README.md) for the quickstart. TL;DR:

```bash
bin/rails db:create
bin/rails db:migrate
bin/rails db:schema:load:cache db:schema:load:queue db:schema:load:cable
bin/rails server -p 3000
# Configure extension/background.js INGEST_URL = http://localhost:3000/capture/ingest
# Paste capture_api_key into the side panel; visit http://localhost:3000 with basic auth.
```

## Deploy

See [README.md](README.md) "Deploy to VPS" — Kamal 2 to a single
server, ghcr.io image, postgres accessory. First-time:
`kamal setup` then `kamal accessory exec db --reuse "psql …"` to create
the cache/queue/cable databases, then `kamal deploy`.

## Out of scope (v1)

- AckRequest controller / mark-as-read endpoint — schema only.
- CSV upload, Product, Offer, AI matcher — see PRODUCTION_PLAN.md.
- Multi-account capture (one Chrome profile, one Discord login).
- Multi-user dashboard auth (single basic-auth user).
- Discord REST API backfill (explicitly avoided — risks burning the account).
- Test suite beyond what `rails new` generates.

## Things to know

- **Discord token cookies are sensitive** — they live in the operator's
  Chrome profile, not in this repo. If the profile is compromised,
  rotate the Discord session (log out everywhere on discord.com).
- **The capture_api_key is the only thing protecting the ingest endpoint**.
  Rotate via `bin/rails credentials:edit` + `kamal deploy`, then update
  the extension popup's API key field.
- **Every new ingest URL the extension talks to must be in
  `extension/manifest.json` `host_permissions`**, or Chrome's CORS
  preflight will block the POST.
- **`MESSAGE_UPDATE` arriving before `MESSAGE_CREATE`** is an edge case we
  accept: the second `create!` for that `(message_id, event_type)` raises
  `RecordNotUnique` and is rescued; the row already exists with the
  older payload. For v1 this is acceptable; in v2 we'd switch back to
  upsert semantics and broadcast separately.
