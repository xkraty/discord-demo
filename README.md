# Discord DM Capture

Captures inbound Discord DMs to a real-time dashboard, via a Chrome
extension + a Rails 8 app deployed with Kamal.

For the project spec (architecture, models, wire format, auth model)
see [CLAUDE.md](CLAUDE.md). For the longer-horizon roadmap (AI matcher,
CSV upload, mark-as-read), see [PRODUCTION_PLAN.md](PRODUCTION_PLAN.md).
This README is the operator runbook.

## Quickstart — local dev

Prereqs: Ruby 3.2+ (4.0.1 used here), Postgres 14+, Docker (optional —
only if you run Postgres in a container).

```bash
# 1. clone
git clone <your-fork> discord-demo && cd discord-demo

# 2. install gems
bundle install

# 3. credentials — generate fresh capture_api_key + basic auth
EDITOR=vim bin/rails credentials:edit
# add:
#   capture_api_key: <random 48+ chars>
#   basic_auth:
#     user: admin
#     pass: <random>

# 4. databases
# Set DB env vars if your Postgres isn't on localhost / pguser:
#   export DB_HOST=localhost DB_USERNAME=pguser
bin/rails db:create
bin/rails db:migrate
bin/rails db:schema:load:cache db:schema:load:queue db:schema:load:cable

# 5. boot
bin/rails server -p 3000
```

Visit http://localhost:3000 and authenticate with the basic_auth
credentials you set. The feed will be empty until the extension sends
events.

### Wire up the Chrome extension

1. Open `extension/background.js`. Set:
   ```js
   const INGEST_URL = "http://localhost:3000/capture/ingest";
   const COMMAND_URL = null;     // mark-as-read not in v1
   ```
2. (Optional — the bundle has pako pre-built. If you ever edit
   `inject.js`, run `extension/build.sh` to rebuild
   `inject.bundle.js`.)
3. Open `chrome://extensions` → Developer mode ON → **Load unpacked** →
   select the `extension/` directory.
4. Click the extension icon → side panel opens.
5. Paste your `capture_api_key` into the API key field → **Save**.
6. Open https://discord.com/channels/@me in another tab — you should
   already be logged in. The side panel's status row turns green.
7. Send/receive a DM; it appears in the side panel feed AND in the
   Rails dashboard at http://localhost:3000.

### Sanity-check the ingest endpoint with curl

```bash
# Set this once
export KEY=<your capture_api_key>

# Empty batch → 200 {accepted: 0}
curl -sS -X POST http://localhost:3000/capture/ingest \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"batch_id":"t1","events":[]}'

# Synthetic DM → 200 {accepted: 1}, row in DB, broadcast fires
curl -sS -X POST http://localhost:3000/capture/ingest \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"batch_id":"t2","events":[{"kind":"gateway_frame","ws_id":1,
       "received_at":"2026-01-01T00:00:00Z",
       "frame":{"op":0,"t":"MESSAGE_CREATE","s":1,
                "d":{"id":"smoke-1","channel_id":"ch-1",
                     "content":"hi","timestamp":"2026-01-01T00:00:00Z",
                     "author":{"id":"a-1","username":"u","global_name":"User"}}}}]}'
```

## Deploy to VPS (Kamal 2)

Prereqs:
- A VPS you can SSH into as `root` (or set `ssh.user` in
  `config/deploy.yml`)
- A domain pointing at it (`<YOUR_DOMAIN> → <YOUR_SERVER_IP>` A record)
- A GitHub account (image lives at ghcr.io)
- Docker installed on your **local** machine (Kamal builds locally,
  pushes to ghcr.io, pulls on the server)

### One-time setup

```bash
# 1. DNS — confirm it resolves
dig +short <YOUR_DOMAIN>     # should print <YOUR_SERVER_IP>

# 2. ghcr.io PAT
# Create a classic token with scopes: write:packages, read:packages
# at https://github.com/settings/tokens
mkdir -p ~/.kamal && chmod 700 ~/.kamal
echo "ghp_xxx..." > ~/.kamal/ghcr-token
chmod 600 ~/.kamal/ghcr-token

# 3. Postgres password
openssl rand -hex 32 > ~/.kamal/discord-demo-pg-password
chmod 600 ~/.kamal/discord-demo-pg-password

# 4. Edit config/deploy.yml:
#    - replace <github-username> with your GitHub user/org
#    - replace sneaker.campoli.me (twice) with your domain if different
#    - confirm servers.web has the right hostname
```

### First deploy

```bash
kamal setup
```

This SSHes in, installs Docker if needed, boots the kamal-proxy, pulls
the Postgres accessory, builds + pushes the Rails image, runs the
container with `db:prepare` on boot. Lets-Encrypt cert provisioning
happens automatically.

**One-off after first setup:** create the three side databases that
Solid Trifecta uses. Rails won't auto-create them.

```bash
kamal accessory exec db --reuse \
  "psql -U discord_demo -d discord_demo_production -c \
   'CREATE DATABASE discord_demo_production_cache; \
    CREATE DATABASE discord_demo_production_queue; \
    CREATE DATABASE discord_demo_production_cable;'"

kamal deploy   # re-run so db:prepare loads cable/cache/queue schemas
```

### Subsequent deploys

```bash
git push                # commit your changes
kamal deploy            # builds, pushes, rolls
kamal app logs -f       # tail
```

### Connect the extension to prod

1. Edit `extension/manifest.json` `host_permissions`: add
   `"https://<YOUR_DOMAIN>/*"` and remove the `webhook.site` /
   `localhost` entries you don't need anymore. Chrome blocks
   cross-origin POSTs to hosts not in this list (CORS preflight).
2. Edit `extension/background.js`:
   ```js
   const INGEST_URL = "https://<YOUR_DOMAIN>/capture/ingest";
   ```
3. `chrome://extensions` → reload the extension. Re-open the side
   panel and confirm the new ingest URL appears.

### Monitor

```bash
kamal app logs -f             # live tail of the web container
kamal logs -r db              # postgres logs
kamal app exec -i "bin/rails console"
kamal app exec -i "bin/rails dbconsole"
```

Dashboard URL: `https://<YOUR_DOMAIN>` — basic auth prompt → live feed.

### Rotating the capture API key

```bash
EDITOR=vim bin/rails credentials:edit   # change capture_api_key
git add config/credentials.yml.enc && git commit -m "Rotate capture_api_key"
kamal deploy
# In Chrome: open side panel → paste new key → Save
```

### Backup the database

```bash
kamal accessory exec db --reuse "pg_dump -U discord_demo discord_demo_production" \
  > backup-$(date +%F).sql
```

## Troubleshooting

**`kamal setup` fails on Let's Encrypt** — DNS hasn't propagated yet,
or `<YOUR_DOMAIN>` isn't resolving to the server. Fix DNS, then
`kamal proxy reboot`.

**Dashboard shows no DMs but the extension's side panel does** — check
SW logs in `chrome://extensions` → service worker → console. Common
causes: ingest URL not added to `host_permissions` (CORS preflight
blocks the POST), wrong API key, server unreachable.

**Ingest POSTs return 401** — `capture_api_key` mismatch. Verify with
`bin/rails runner 'puts Rails.application.credentials.capture_api_key'`.

**Realtime broadcasts don't reach the browser in prod** — check Solid
Cable is running and `solid_cable_messages` in the cable DB has rows:
```bash
kamal accessory exec db --reuse \
  "psql -U discord_demo -d discord_demo_production_cable \
   -c 'SELECT count(*) FROM solid_cable_messages;'"
```

**MV3 service worker keeps dying** — extension uses a long-lived port
+ alarms to keep itself alive while a Discord tab is open. If you see
gaps in capture, look for `bridge_disconnected` lines in the SW
console.
