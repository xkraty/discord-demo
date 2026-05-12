# Production system plan

This document plans the production system that follows once the demo's 7-day
capture reliability is proven. The demo (this repo) validates the capture
mechanism; this plan builds the business system around it.

**Status**: planning only. Do not implement until the demo's acceptance criteria
in `CLAUDE.md` are met.

---

## North-star description

A Rails 8 application that:

1. Continuously captures inbound Discord DMs to the operator's account via a
   long-lived Playwright-driven Chromium session (proven by this demo).
2. Lets the operator upload a daily CSV of "want to buy" products.
3. Uses AI to match each inbound seller DM to the correct product in the CSV.
4. Presents matched offers in a dashboard the operator triages — they reply
   manually from Discord. **No outbound automation in v1.**
5. Runs reliably enough for 5+ days of unattended operation between deploys.

The operator's daily flow becomes: upload CSV → check dashboard → review matched
offers (free text + product they match + confidence) → reply manually for the
ones they want to accept.

---

## Stack (chosen)

- **Rails 8** with Hotwire (Turbo + Stimulus)
- **Tailwind CSS** + **importmap** (no Node build step)
- **Solid Trifecta**: Solid Queue, Solid Cache, Solid Cable (no Redis)
- **Mission Control - Jobs** for queue UI
- **Kamal 2** for deployment
- **Postgres** (single instance, hosted on the same Kamal target server in v1)
- **Capture worker**: separate Ruby process (Playwright + the gateway hook from
  this demo), running as a Kamal accessory next to the Rails app

---

## Architecture

```
┌──────────────────────── Kamal target server ────────────────────────┐
│                                                                     │
│  ┌─────────────────────┐  ┌──────────────────────────────────────┐  │
│  │ chromium accessory  │  │ rails app                            │  │
│  │ (lscr.io/.../chrom) │  │ (puma + solid_queue supervisor)      │  │
│  │ + chromium-proxy    │  │  GET /chromium ──► X-Accel-Redirect  │  │
│  │   (nginx sidecar)   │◄─┼─────────────────── to noVNC via proxy│  │
│  │ Discord session     │  │  reads dashboard, presents offers    │  │
│  └─────────┬───────────┘  │                                      │  │
│            │ CDP 9223     │                                      │  │
│  ┌─────────▼───────────┐  │                                      │  │
│  │ capture accessory   │  │                                      │  │
│  │ (Ruby + Playwright) │──┼──► writes captured events to Postgres│  │
│  │ "discord-capture"   │  │    (same DB as Rails)                │  │
│  └─────────────────────┘  └──────────────────────────────────────┘  │
│                                       │                             │
│                              ┌────────▼────────┐                    │
│                              │   postgres      │                    │
│                              │   accessory     │                    │
│                              └─────────────────┘                    │
└─────────────────────────────────────────────────────────────────────┘
```

### Why separate capture worker (not in Rails)

- Rails deploys kill long-lived processes. Capture holds a stateful WebSocket;
  killing it every deploy means a 30+ second gap of missed messages and a
  visible reconnect pattern Discord could fingerprint.
- The capture worker is the same Ruby script from the demo, scaled up. Single
  responsibility: hold the WS open, write rows to Postgres.
- Capture survives `kamal deploy`. Only `kamal accessory restart capture` (a
  rare, intentional operation) interrupts it.

### Why direct DB writes (not HTTP)

- Both processes are on the same server; HTTP would be a network hop and an
  auth surface for no gain.
- Rails picks up new rows via Solid Queue: capture inserts a `MESSAGE_CREATE`
  row, an after-insert trigger (or a small poller) enqueues a `MatchOfferJob`.
- Postgres LISTEN/NOTIFY is an option for lower-latency pickup but adds little
  at this volume (~5 inbound DMs per product × 100 products = 500/day peak).

---

## Domain model (initial)

```ruby
# Captured Discord data (mirrors the demo schema)
class DiscordMessage < ApplicationRecord
  # discord_message_id, discord_channel_id, discord_author_id,
  # author_username, author_display_name, event_type, content,
  # timestamp_iso, is_dm (bool), raw_payload (jsonb), captured_at
end

class DiscordSessionEvent < ApplicationRecord
  # event, detail, occurred_at  (gateway_open, gateway_close, heartbeat, ...)
end

# Business domain
class Product < ApplicationRecord
  # uploaded from CSV; sku, model, size, target_price, listed_at, status
  # status: "open" | "filled" | "cancelled"
  has_many :offers
end

class Offer < ApplicationRecord
  belongs_to :product, optional: true    # null until matched, may stay null
  belongs_to :discord_message            # the inbound DM
  # seller_username, seller_user_id, content (text)
  # match_confidence (0.0..1.0), match_reason (text from LLM)
  # status: "unmatched" | "matched" | "dismissed" | "accepted"
  # accepted_at, dismissed_at
end

class CsvUpload < ApplicationRecord
  has_many :products
  # file (Active Storage), uploaded_by, processed_at, row_count, error_count
end
```

`raw_payload` is preserved on `DiscordMessage` for reprocessing — if the matcher
improves, we re-run it against history without going back to Discord.

---

## Capture worker (extracted from this demo)

Same code as `src/capture.rb` / `src/gateway.rb`, with these changes:

1. Writes to Postgres instead of SQLite. ActiveRecord models from Rails are
   reused — the capture worker `require`s the Rails environment or, simpler,
   uses a tiny `Sequel`/`pg`-backed model layer that hits the same tables.
2. Reads config from Rails credentials (`Rails.application.credentials`) so the
   Discord cookie store path, proxy URL, and database connection all live in
   one place.
3. Loops `kamal accessory restart capture` as the disaster-recovery primitive
   rather than `Ctrl-C`.
4. Same passive-observer constraints: no DOM scraping, no sending, no clicking.

The Chromium accessory keeps the same image (`lscr.io/linuxserver/chromium`) but
the demo's `socat` cdp-proxy sidecar is replaced with an nginx sidecar
(`chromium-proxy` accessory, `network_mode: service:chromium`) that does two
jobs in one:

- **TCP proxy** on `:9223` → `127.0.0.1:9222` for CDP (still required —
  Chromium ignores `--remote-debugging-address=0.0.0.0` in this image and
  binds CDP to loopback only).
- **HTTP/WS proxy** on `:3010` → `127.0.0.1:3000` for noVNC, gated entirely
  by Rails via `X-Accel-Redirect`. The Chromium accessory's built-in noVNC
  password is disabled — only nginx in the shared netns can reach noVNC, and
  nginx only serves it on behalf of authenticated Rails requests.

The capture worker connects to the nginx sidecar's `:9223` for CDP. From its
perspective nothing changes vs. the demo — same URL, same protocol.

### Residential proxy

Configured at the Chromium level via `--proxy-server=http://user:pass@host:port`
in the `CHROME_CLI` env var. Only Chromium traffic goes through the proxy; Rails
and DB traffic use normal egress. This keeps proxy bandwidth costs minimal and
keeps Kamal management traffic off the proxy.

Proxy credentials live in Rails credentials and are templated into the
Kamal accessory config at deploy time.

---

## AI matching

Decision deferred. Design with a clean `MatcherService` interface:

```ruby
class MatcherService
  Result = Struct.new(:product, :confidence, :reason)

  def match(offer)
    # Implementations to try:
    #   - LlmMatcher (Claude/OpenAI, one call per DM with CSV in context)
    #   - EmbeddingMatcher (deterministic, cheap)
    #   - HybridMatcher (embeddings shortlist + LLM confirm)
    raise NotImplementedError
  end
end
```

`MatchOfferJob` (Solid Queue) calls the configured implementation, persists the
result on the `Offer` row, and the dashboard reads from there.

Cost ceiling to keep in mind: at ~€4–5 margin/pair, the matching cost per offer
needs to stay well under €0.10 or it eats meaningful margin. LLM-per-call is
fine; running an LLM on every gateway frame would not be.

---

## Dashboard (v1 scope)

Stimulus + Turbo, three views:

1. **Inbox** — list of recent `Offer` rows, default sort by `created_at` desc.
   Each row shows: seller username, message preview, matched product + size +
   target price, confidence badge. Click → detail view.
2. **Offer detail** — full DM thread for that seller in that channel
   (last N messages from the same `discord_channel_id`), matched product
   details, "Mark accepted" / "Dismiss" actions. **No reply UI in v1** —
   operator replies in Discord manually.
3. **CSV upload** — drag-drop, preview parsed rows, confirm, replaces today's
   open products. Soft-delete strategy so we don't lose match history.

Plus a small system-health panel showing: last gateway open/close, time since
last heartbeat, last captured message, current Discord page URL (for "are we
still logged in?" sanity).

### Chromium access route

A single Rails route at `/chromium` reuses the existing admin auth gate and
embeds noVNC via `X-Accel-Redirect` (same pattern as the operator's Icecast
project). One controller, three actions (HTML, asset path, WS upgrade), all
guarded by the same `current_user&.admin?` check. nginx serves the bytes once
Rails authorizes them — Rails never touches the noVNC socket. No separate
noVNC password.

---

## Deployment (Kamal)

`config/deploy.yml` outline:

```yaml
service: discord-capture
image: <registry>/discord-capture

servers:
  web:
    - <single server IP>

accessories:
  postgres:
    image: postgres:17
    # standard kamal postgres accessory

  chromium:
    image: lscr.io/linuxserver/chromium:latest
    # noVNC built-in password is disabled — nginx + Rails are the only gate
    env:
      clear:
        CUSTOM_USER: admin
        PASSWORD: ""
        CHROME_CLI: --remote-debugging-port=9222 --remote-debugging-address=0.0.0.0
                    --proxy-server=...        # from credentials
                    --disable-blink-features=AutomationControlled
    volumes:
      - chromium-profile:/config
    options:
      shm-size: 2gb
      publish:
        - "127.0.0.1:9223:9223"   # CDP via nginx sidecar
        - "127.0.0.1:3010:3010"   # noVNC via nginx sidecar (Rails reaches this)

  chromium-proxy:
    image: nginx:1.27-alpine
    network_mode: container:chromium-accessory
    volumes:
      - ./config/nginx-chromium-proxy.conf:/etc/nginx/nginx.conf:ro

  capture:
    image: <registry>/discord-capture-worker  # built from same repo, separate Dockerfile
    cmd: bundle exec ruby capture.rb
    env:
      clear:
        CHROMIUM_CDP_URL: http://chromium:9223
      secret:
        - DATABASE_URL
        - RAILS_MASTER_KEY
```

**One-time bootstrap step that can't be in Kamal**: log in to Discord via
`/chromium` in the Rails dashboard the first time the Chromium accessory comes
up. The session cookies persist in the `chromium-profile` volume, so this is
a one-time-per-account operation. Because `/chromium` is gated by Rails admin
auth, no separate firewall rule for noVNC is needed.

**Daily-driver migration path**: stays out of scope until the test account has
run cleanly for 30+ days with the proxy. When migrating, the steps are:
(1) clone the chromium-profile volume from the test setup as a template, (2)
log in to the daily-driver via noVNC into that cloned profile, (3) swap which
profile the capture worker points at. No code changes.

---

## Observability

- **Mission Control - Jobs** at `/jobs` (basic auth, ops-only) for Solid Queue.
- **Capture health check**: a Rails endpoint `/internal/capture_health` returns
  `{ last_heartbeat_at, last_message_at, gateway_open_count_last_hour,
  gateway_close_count_last_hour }`. Free with the existing `session_events`
  table. Wired into UptimeRobot or similar with a 5-minute check.
- **Alerts to Discord (separate webhook)**: a tiny Solid Queue periodic job
  posts to an alerting Discord webhook if no heartbeat in 5 minutes OR no
  `MESSAGE_CREATE` of any kind in 60 minutes (probably means the gateway is
  dead even if the worker is alive).
- **Log shipping**: Kamal's default `journalctl`-style is fine; revisit if it
  becomes a problem.

---

## Security and account hygiene

- Discord session cookies are the only credential that matters for capture.
  Treat the `chromium-profile` volume as a secret — back it up encrypted to S3
  weekly. Losing it means re-logging in (and a captcha challenge from a new IP
  is likely).
- The Chromium accessory's noVNC has no password of its own. Rails session
  auth is the only gate, served via `X-Accel-Redirect` through the
  `chromium-proxy` nginx sidecar. The public internet sees only Rails.
- Auto-replies are explicitly out of scope for v1, which keeps the account in
  pure "passive read" mode — the safest possible posture.
- Proxy credentials and Rails master key go into Kamal's secret store, not
  env files.
- No PII from sellers should leave the box: AI calls send the message text but
  not Discord IDs. Document this in the privacy note.

---

## Out of scope for production v1

These are explicitly *not* built in v1 even though they're tempting:

- Auto-replies (deferred to v2 after matching is trusted for 30+ days).
- Multi-account capture (one Discord account per deployment).
- Mobile dashboard (operator works from a laptop).
- Slack/email notifications (alerts go to a dedicated Discord channel, dogfooding the same medium the business runs on).
- Historical Discord backfill via REST API — explicitly avoided. Using
  Discord's REST API would expose a different fingerprint than the web
  client's WS and risks burning the account. Gaps are logged and surfaced;
  operator handles them manually.
- Multi-region, HA Postgres, read replicas. One server, one DB, snapshots.
- A separate "matcher tuning" UI. Iterate the matcher in code + a Rails
  console workflow.

---

## Build order (when green-lit)

1. Rails 8 app skeleton with Solid Trifecta and Mission Control. Verify Kamal
   deploy works on the target server with a "hello world" page.
2. Postgres schema for `DiscordMessage`, `DiscordSessionEvent`, `Product`,
   `Offer`, `CsvUpload`. Migration + factories + model tests.
3. Port the demo's `src/` into a `capture/` directory in the Rails repo,
   replace SQLite with Postgres via ActiveRecord. Verify it still captures
   messages from the test account when run locally against the prod schema.
4. Build the Chromium + chromium-proxy (nginx) + capture Kamal accessories.
   Deploy. Verify capture survives a Rails deploy AND that `/chromium` in
   Rails opens an authenticated noVNC view.
5. CSV upload + Product model + dashboard inbox showing unmatched offers (no
   matching yet, just raw DM list).
6. `MatcherService` interface + first implementation (probably
   `LlmMatcher` for simplicity). Wire it into `MatchOfferJob`.
7. Offer detail view with thread context + accept/dismiss actions.
8. Capture health endpoint + Discord-webhook alerts.
9. Operator dogfoods for a week with real CSV data. Iterate matcher accuracy.
10. Daily-driver migration (if metrics support it).

Each step is a deployable increment.

---

## What still needs deciding

These can be deferred but should be revisited before step 6:

- **Matcher implementation** — LLM-only, embeddings, or hybrid. Decide after
  step 5 when we have real offer data to test against.
- **CSV format and required columns** — get a real sample CSV from the
  operator and pin the schema before building the upload flow.
- **Offer ↔ DM thread relationship** — is one Offer one message, or is it the
  whole back-and-forth with one seller about one product? Probably the
  latter, but it affects the schema. Worth a short spike before step 2.
- **Confidence threshold for auto-matching vs "needs review"** — defer until
  matcher exists and we can look at distribution.
- **noVNC path-rewriting spike** — does the linuxserver/chromium noVNC build
  serve correctly when proxied through nginx with absolute internal paths
  (`/_internal/novnc/`)? Some noVNC builds embed absolute URLs that break
  reverse-proxying. ~1 hour spike before committing. Fallback if it breaks:
  dedicated `chromium.<host>` subdomain with a short-lived signed cookie
  issued by Rails as the auth token (no path rewriting needed).
