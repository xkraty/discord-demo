// MV3 service worker. Receives gateway frames from content scripts via
// long-lived ports, batches them, POSTs to Rails, and long-polls Rails for
// outbound commands (currently only mark-as-read ACK).

// ---- config -----------------------------------------------------------------

// Hard-coded ingest URLs per operator decision. For local dev, set to localhost.
// Set INGEST_URL to null (or empty string) to disable Rails ingest entirely —
// useful for viewer-only mode where you just want to watch frames in the side
// panel without persisting them anywhere.
const INGEST_URL  = "https://webhook.site/8245eec1-cd53-4e0e-81d6-b9c2443fad81";
const COMMAND_URL = null;
const COMMAND_ACK_URL = (id) => `${COMMAND_URL?.replace(/\/commands$/, '')}/commands/${id}/ack`;
const INGEST_DISABLED = !INGEST_URL;

const FLUSH_MAX_EVENTS = 50;
const FLUSH_MAX_MS     = 1000;
const QUEUE_CAP        = 5000;
const BACKOFFS_MS      = [2_000, 5_000, 15_000, 60_000, 300_000];

// Event filter (matches PRODUCTION_PLAN.md "Gateway events captured in v1").
const MESSAGE_T = new Set(['MESSAGE_CREATE', 'MESSAGE_UPDATE', 'MESSAGE_DELETE', 'CHANNEL_CREATE']);
const ACK_T     = new Set(['MESSAGE_ACK']);
const SESSION_T = new Set(['READY', 'READY_SUPPLEMENTAL', 'SESSIONS_REPLACE']);

// ---- in-memory state --------------------------------------------------------

const STATE = {
  apiKey:        null,
  profileId:     null,
  queue:         [],       // pending events to POST
  lastFrameAt:   null,
  lastFlushAt:   null,
  lastFlushOk:   null,     // true | false | null
  lastError:     null,
  gatewaysOpen:  new Set(),// wsIds across all tabs
  framesSeen:    0,
  flushes:       0,
  bridges:       new Map(),// portId -> Port (content scripts)
  nextBridgeId:  1,
  pendingCmds:   new Map(),// cmdId -> { command_id, sentAt, timer }
  flushTimer:    null,
  backoffStep:   0,
  backoffTimer:  null,

  // Subscribers for the live feed (side panel).
  subscribers:   new Set(),// Port
  // Ring buffer of recent events (for side panel late-attach so it gets history).
  recent:        [],
  recentMax:     200,

  // channelId -> display name. Populated from READY's private_channels +
  // guilds[].channels, and updated on CHANNEL_CREATE/UPDATE.
  channelNames:  new Map(),
};

// ---- bootstrap --------------------------------------------------------------

(async function init() {
  const stored = await chrome.storage.local.get(['apiKey', 'profileId', 'queue', 'lastFrameAt', 'lastFlushAt', 'lastError']);
  STATE.apiKey      = stored.apiKey || null;
  STATE.profileId   = stored.profileId || crypto.randomUUID();
  STATE.queue       = Array.isArray(stored.queue) ? stored.queue : [];
  STATE.lastFrameAt = stored.lastFrameAt || null;
  STATE.lastFlushAt = stored.lastFlushAt || null;
  STATE.lastError   = stored.lastError || null;

  if (!stored.profileId) {
    await chrome.storage.local.set({ profileId: STATE.profileId });
  }

  log('init', { queueDepth: STATE.queue.length, hasKey: !!STATE.apiKey });

  // If we have leftover queue from a previous SW lifetime, try a flush.
  if (STATE.queue.length) scheduleFlush(0);

  // Start the long-poll loop for outbound commands.
  startCommandLoop();
})();

// Keepalive alarm (belt-and-braces alongside the port pings).
chrome.alarms.create('keepalive', { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name === 'keepalive') {
    // No-op — the wakeup itself is the point. But while we're here, drain
    // the queue if anything pending.
    if (STATE.queue.length && !STATE.flushTimer && !STATE.backoffTimer) scheduleFlush(0);
  }
});

// ---- port handling ----------------------------------------------------------

chrome.runtime.onConnect.addListener((port) => {
  if (port.name === 'capture-bridge') {
    const bridgeId = STATE.nextBridgeId++;
    STATE.bridges.set(bridgeId, port);
    log('bridge_connected', { bridgeId, total: STATE.bridges.size });

    port.onMessage.addListener((msg) => handleBridgeMessage(bridgeId, port, msg));

    port.onDisconnect.addListener(() => {
      STATE.bridges.delete(bridgeId);
      log('bridge_disconnected', { bridgeId, remaining: STATE.bridges.size });
    });
    return;
  }

  if (port.name === 'capture-sidepanel') {
    STATE.subscribers.add(port);
    log('sidepanel_connected', { total: STATE.subscribers.size });

    // Replay recent events so the panel has history immediately.
    try { port.postMessage({ kind: 'replay', events: STATE.recent.slice() }); } catch (_) {}

    port.onMessage.addListener((msg) => {
      // Reserved for future side-panel-initiated actions (e.g. clear log).
      if (msg?.kind === 'clear_recent') {
        STATE.recent = [];
        broadcast({ kind: 'cleared' });
      }
    });

    port.onDisconnect.addListener(() => {
      STATE.subscribers.delete(port);
      log('sidepanel_disconnected', { remaining: STATE.subscribers.size });
    });
    return;
  }
});

// Side panel: clicking the toolbar icon opens the side panel.
// When openPanelOnActionClick is true, Chrome handles the click itself and
// action.onClicked does NOT fire — they're mutually exclusive.
chrome.sidePanel?.setPanelBehavior?.({ openPanelOnActionClick: true })
  .catch((e) => log('sidepanel_setbehavior_failed', { err: String(e).slice(0, 200) }));

function broadcast(msg) {
  for (const port of STATE.subscribers) {
    try { port.postMessage(msg); } catch (_) { /* dead port; will get cleaned by onDisconnect */ }
  }
}

function pushRecent(item) {
  STATE.recent.push(item);
  if (STATE.recent.length > STATE.recentMax) {
    STATE.recent.splice(0, STATE.recent.length - STATE.recentMax);
  }
}

function handleBridgeMessage(bridgeId, port, msg) {
  if (!msg || typeof msg.kind !== 'string') return;
  const { kind, payload } = msg;

  switch (kind) {
    case 'ping':
    case 'hello':
      // Keepalive only; nothing to enqueue.
      return;

    case 'gateway_open':
      STATE.gatewaysOpen.add(payload.wsId);
      enqueueSession('gateway_open', payload.wsId, payload.url || null);
      return;

    case 'gateway_close':
      STATE.gatewaysOpen.delete(payload.wsId);
      enqueueSession('gateway_close', payload.wsId, JSON.stringify({
        code: payload.code, reason: payload.reason, wasClean: payload.wasClean,
      }));
      return;

    case 'gateway_error':
      enqueueSession('gateway_error', payload.wsId, null);
      return;

    case 'decompress_error':
      enqueueSession('decompress_error', payload.wsId, payload.message || null);
      return;

    case 'gateway_frame':
      STATE.framesSeen++;
      STATE.lastFrameAt = Date.now();
      handleFrame(payload);
      return;

    case 'cmd_ack':
      handleCmdAck(payload);
      return;

    default:
      // Unknown kind — log to session events for visibility.
      enqueueSession('unknown_bridge_kind', null, kind);
  }
}

function handleFrame(payload) {
  const { wsId, text, ts, selftest } = payload;
  let frame;
  try {
    frame = JSON.parse(text);
  } catch (_) {
    enqueueRaw(wsId, text);
    broadcastFrame({ wsId, frame: null, raw: text.slice(0, 500), ts, selftest, dispatched: false });
    return;
  }
  if (!frame || typeof frame !== 'object') return;

  const t = frame.t;
  let dispatched = false;
  let isSession  = false;

  // Update the channel-name lookup from any event that carries channel info.
  // Runs before dispatch so the lookup is populated before we render summaries.
  updateChannelNamesFromFrame(frame);

  // Dispatch and session events filter.
  if (typeof t === 'string') {
    if (MESSAGE_T.has(t) || ACK_T.has(t)) {
      enqueueFrame(wsId, frame, ts, selftest);
      dispatched = true;
    } else if (SESSION_T.has(t)) {
      // enqueueSession() will broadcast a 'session' item to the side panel —
      // we do NOT also push a 'frame' item for the same event below, to avoid
      // double rows.
      enqueueSession(t, wsId, summarizeSessionFrame(frame));
      dispatched = true;
      isSession  = true;
    }
    // Heartbeats / presence / typing / voice etc. are dropped (not enqueued).
  }

  // Broadcast as a "frame" row to the side panel — but skip session-type events
  // because they were already broadcast via enqueueSession.
  if (!isSession) {
    broadcastFrame({ wsId, frame, ts, selftest, dispatched });
  }
}

// Discord gateway opcodes — for naming frames where t is null.
// https://discord.com/developers/docs/topics/opcodes-and-status-codes
const OPCODE_NAMES = {
  0:  'DISPATCH',     // unused here — these have a t
  1:  'HEARTBEAT',    // server asks us to heartbeat now
  2:  'IDENTIFY',     // outbound (we don't capture)
  3:  'PRESENCE',     // outbound
  4:  'VOICE_STATE',  // outbound
  6:  'RESUME',       // outbound
  7:  'RECONNECT',    // server tells us to reconnect
  8:  'REQ_MEMBERS',  // outbound
  9:  'INVALID_SES',  // session invalidated
  10: 'HELLO',        // initial server greeting
  11: 'HEARTBEAT_ACK',
};

function broadcastFrame(item) {
  const t  = item.frame?.t;
  const op = item.frame?.op;
  const label = t
    || (op != null ? (OPCODE_NAMES[op] || `op:${op}`) : (item.raw ? '<raw>' : '<unknown>'));
  const enriched = {
    kind:       'frame',
    wsId:       item.wsId,
    t:          label,
    op,
    dispatched: !!item.dispatched,
    selftest:   !!item.selftest,
    received_at: new Date(item.ts || Date.now()).toISOString(),
    summary:    summarizeFrameForFeed(item.frame),
    raw:        item.raw || null,
  };
  pushRecent(enriched);
  broadcast(enriched);
}

function broadcastSession(event, wsId, detail) {
  const enriched = {
    kind:        'session',
    event,
    wsId,
    detail,
    occurred_at: new Date().toISOString(),
  };
  pushRecent(enriched);
  broadcast(enriched);
}

// Build a one-line summary the side panel can render cheaply.
function summarizeFrameForFeed(frame) {
  if (!frame || typeof frame !== 'object') return null;
  const t = frame.t;
  const d = frame.d || {};
  switch (t) {
    case 'MESSAGE_CREATE':
    case 'MESSAGE_UPDATE': {
      const author = d.author?.global_name || d.author?.username || '(unknown)';
      const isDm = d.guild_id == null;
      return {
        author,
        is_dm: isDm,
        channel_id: d.channel_id,
        channel_name: channelNameFor(d.channel_id),
        message_id: d.id,
        preview: (d.content || '').slice(0, 200),
      };
    }
    case 'MESSAGE_DELETE':
      return {
        channel_id: d.channel_id,
        channel_name: channelNameFor(d.channel_id),
        message_id: d.id,
        is_dm: d.guild_id == null,
      };
    case 'MESSAGE_ACK':
      return {
        channel_id: d.channel_id,
        channel_name: channelNameFor(d.channel_id),
        message_id: d.message_id,
        ack_version: d.version,
      };
    case 'CHANNEL_CREATE':
      return { channel_id: d.id, type: d.type, recipient_count: d.recipients?.length };
    case 'TYPING_START':
      return { channel_id: d.channel_id, user_id: d.user_id };
    case 'PRESENCE_UPDATE':
      return { user_id: d.user?.id, status: d.status };
    default:
      return { keys: Object.keys(d).slice(0, 6) };
  }
}

// Extract a human label from a Discord channel object, regardless of type.
// DMs (type 1): the lone recipient's username. Group DMs (type 3): the name
// field if set, else "DM: a, b, c". Server channels (text/voice/etc.):
// "#name" with the channel's actual name.
function labelForChannel(ch) {
  if (!ch || typeof ch !== 'object') return null;
  const id = ch.id;
  if (!id) return null;
  if (ch.type === 1) {
    const r = (ch.recipients || ch.recipient_ids || [])[0];
    const name = (r && (r.global_name || r.username)) || ch.recipient_username || null;
    return name ? `DM: ${name}` : 'DM';
  }
  if (ch.type === 3) {
    if (ch.name) return `DM: ${ch.name}`;
    const recips = (ch.recipients || []).map((r) => r.global_name || r.username).filter(Boolean);
    if (recips.length) return `DM: ${recips.join(', ')}`;
    return 'Group DM';
  }
  if (ch.name) return `#${ch.name}`;
  return null;
}

function updateChannelNamesFromFrame(frame) {
  if (!frame || typeof frame !== 'object') return;
  const d = frame.d;
  if (!d || typeof d !== 'object') return;
  const t = frame.t;

  // READY: bulk-populate from private_channels + guilds[].channels.
  if (t === 'READY') {
    for (const ch of d.private_channels || []) {
      const name = labelForChannel(ch);
      if (name) STATE.channelNames.set(ch.id, name);
    }
    for (const g of d.guilds || []) {
      for (const ch of g.channels || []) {
        const name = labelForChannel(ch);
        if (name) STATE.channelNames.set(ch.id, name);
      }
    }
    return;
  }

  // READY_SUPPLEMENTAL has merged_members + merged_presences but no channels.

  // CHANNEL_CREATE/UPDATE: single channel object as d.
  if (t === 'CHANNEL_CREATE' || t === 'CHANNEL_UPDATE') {
    const name = labelForChannel(d);
    if (name && d.id) STATE.channelNames.set(d.id, name);
    return;
  }

  // GUILD_CREATE: full guild snapshot with channels.
  if (t === 'GUILD_CREATE') {
    for (const ch of d.channels || []) {
      const name = labelForChannel(ch);
      if (name) STATE.channelNames.set(ch.id, name);
    }
    return;
  }
}

function channelNameFor(channelId) {
  if (!channelId) return null;
  return STATE.channelNames.get(channelId) || null;
}

function summarizeSessionFrame(frame) {
  try {
    const d = frame.d || {};
    const summary = {
      t: frame.t,
      // For READY: user id + private channels count.
      user_id: d.user?.id,
      private_channel_count: Array.isArray(d.private_channels) ? d.private_channels.length : undefined,
      guild_count:           Array.isArray(d.guilds) ? d.guilds.length : undefined,
      session_id: d.session_id,
    };
    return JSON.stringify(summary).slice(0, 500);
  } catch (_) {
    return null;
  }
}

// ---- queue ------------------------------------------------------------------

function enqueueFrame(wsId, frame, ts, selftest) {
  push({
    kind: 'gateway_frame',
    ws_id: wsId,
    received_at: new Date(ts || Date.now()).toISOString(),
    selftest: !!selftest,
    frame,
  });
}

function enqueueSession(event, wsId, detail) {
  const d = detail == null ? null : String(detail).slice(0, 1000);
  push({
    kind: 'gateway_session',
    ws_id: wsId,
    event,
    detail: d,
    occurred_at: new Date().toISOString(),
  });
  broadcastSession(event, wsId, d);
}

function enqueueRaw(wsId, text) {
  push({
    kind: 'gateway_raw',
    ws_id: wsId,
    received_at: new Date().toISOString(),
    text: (text || '').slice(0, 2000),
  });
}

function push(item) {
  STATE.queue.push(item);
  if (STATE.queue.length > QUEUE_CAP) {
    const dropped = STATE.queue.length - QUEUE_CAP;
    STATE.queue.splice(0, dropped);
    STATE.queue.push({
      kind: 'gateway_session',
      ws_id: null,
      event: 'queue_overflow',
      detail: `dropped=${dropped}`,
      occurred_at: new Date().toISOString(),
    });
  }
  if (STATE.queue.length >= FLUSH_MAX_EVENTS) {
    scheduleFlush(0);
  } else if (!STATE.flushTimer && !STATE.backoffTimer) {
    scheduleFlush(FLUSH_MAX_MS);
  }
}

function scheduleFlush(delay) {
  if (STATE.flushTimer) clearTimeout(STATE.flushTimer);
  STATE.flushTimer = setTimeout(flush, delay);
}

async function flush() {
  STATE.flushTimer = null;
  if (STATE.queue.length === 0) return;
  if (INGEST_DISABLED) {
    // Viewer-only mode. Drop the queue silently — side panel still gets frames
    // because broadcasting happens before enqueue.
    STATE.queue.length = 0;
    return;
  }
  if (!STATE.apiKey) {
    // Without an API key we can't POST; hold the queue and try later.
    log('flush_skipped', { reason: 'no_api_key', queueDepth: STATE.queue.length });
    scheduleBackoff();
    return;
  }

  // Snapshot up to QUEUE_CAP for this batch.
  const batch = STATE.queue.splice(0, STATE.queue.length);
  const batchId = crypto.randomUUID();
  const body = JSON.stringify({
    batch_id: batchId,
    client: {
      extension_version: chrome.runtime.getManifest().version,
      profile_id: STATE.profileId,
    },
    events: batch,
  });

  try {
    const res = await fetch(INGEST_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${STATE.apiKey}`,
        'X-Batch-Id': batchId,
      },
      body,
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    STATE.lastFlushAt = Date.now();
    STATE.lastFlushOk = true;
    STATE.lastError = null;
    STATE.flushes++;
    STATE.backoffStep = 0;
    await persistMeta();
    log('flush_ok', { count: batch.length, batchId });
  } catch (e) {
    STATE.lastFlushOk = false;
    STATE.lastError = String(e).slice(0, 200);
    // Restore batch to the head of the queue.
    STATE.queue = batch.concat(STATE.queue).slice(0, QUEUE_CAP);
    await persistQueue();
    log('flush_failed', { err: STATE.lastError, queueDepth: STATE.queue.length });
    scheduleBackoff();
  }
}

function scheduleBackoff() {
  if (STATE.backoffTimer) return;
  const wait = BACKOFFS_MS[Math.min(STATE.backoffStep, BACKOFFS_MS.length - 1)];
  STATE.backoffStep = Math.min(STATE.backoffStep + 1, BACKOFFS_MS.length - 1);
  STATE.backoffTimer = setTimeout(() => {
    STATE.backoffTimer = null;
    flush();
  }, wait);
}

async function persistQueue() {
  try {
    await chrome.storage.local.set({
      queue: STATE.queue,
      lastFrameAt: STATE.lastFrameAt,
      lastFlushAt: STATE.lastFlushAt,
      lastError: STATE.lastError,
    });
  } catch (e) {
    log('persist_queue_failed', { err: String(e).slice(0, 200) });
  }
}

async function persistMeta() {
  try {
    await chrome.storage.local.set({
      lastFrameAt: STATE.lastFrameAt,
      lastFlushAt: STATE.lastFlushAt,
      lastError:   STATE.lastError,
      queue:       STATE.queue,
    });
  } catch (_) {}
}

// ---- command long-poll ------------------------------------------------------

let commandLoopRunning = false;

async function startCommandLoop() {
  if (commandLoopRunning) return;
  if (INGEST_DISABLED) {
    log('command_loop_disabled', { reason: 'INGEST_URL not configured' });
    return;
  }
  commandLoopRunning = true;
  while (commandLoopRunning) {
    if (!STATE.apiKey) {
      await sleep(5_000);
      continue;
    }
    try {
      const res = await fetch(COMMAND_URL, {
        method: 'GET',
        headers: { 'Authorization': `Bearer ${STATE.apiKey}` },
      });
      if (res.status === 200) {
        const cmd = await res.json();
        await dispatchCommand(cmd);
      } else if (res.status === 204) {
        // No command, immediately loop.
      } else {
        log('command_poll_http', { status: res.status });
        await sleep(5_000);
      }
    } catch (e) {
      log('command_poll_err', { err: String(e).slice(0, 200) });
      await sleep(5_000);
    }
  }
}

async function dispatchCommand(cmd) {
  if (!cmd || !cmd.command_id) {
    log('command_invalid', cmd);
    return;
  }
  if (cmd.kind === 'send_ack') {
    // Build the ACK frame. NOTE: exact opcode/payload to be confirmed from a
    // captured real outbound ACK; this is a placeholder.
    // Discord gateway: outbound payloads have shape {op, d}.
    const ackFrame = {
      op: 3, // PLACEHOLDER. Update after observing a real client ACK.
      d: {
        channel_id: cmd.channel_id,
        message_id: cmd.message_id,
      },
    };
    const text = JSON.stringify(ackFrame);
    await sendOnGateway(cmd.command_id, text);
    return;
  }
  // Unknown kind — ack as failed so Rails doesn't keep re-sending it.
  await ackCommand(cmd.command_id, false, `unknown_command_kind:${cmd.kind}`);
}

function sendOnGateway(commandId, text) {
  return new Promise((resolve) => {
    const cmdId = crypto.randomUUID();
    let resolved = false;
    const timer = setTimeout(() => {
      if (resolved) return;
      resolved = true;
      STATE.pendingCmds.delete(cmdId);
      ackCommand(commandId, false, 'cmd_timeout').then(resolve);
    }, 10_000);
    STATE.pendingCmds.set(cmdId, { commandId, resolve, timer, resolved: false });

    // Broadcast to all bridges. The MAIN-world hook addresses the active
    // gateway in whichever tab still has one.
    let any = false;
    for (const port of STATE.bridges.values()) {
      try {
        port.postMessage({ kind: 'send_on_gateway', payload: { cmdId, text } });
        any = true;
      } catch (_) { /* skip dead port */ }
    }
    if (!any) {
      clearTimeout(timer);
      STATE.pendingCmds.delete(cmdId);
      ackCommand(commandId, false, 'no_bridges').then(resolve);
    }
  });
}

function handleCmdAck(payload) {
  const { cmdId, ok, error } = payload || {};
  const entry = STATE.pendingCmds.get(cmdId);
  if (!entry || entry.resolved) return;
  entry.resolved = true;
  clearTimeout(entry.timer);
  STATE.pendingCmds.delete(cmdId);
  ackCommand(entry.commandId, !!ok, error || null).then(entry.resolve);
}

async function ackCommand(commandId, ok, error) {
  try {
    await fetch(COMMAND_ACK_URL(commandId), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${STATE.apiKey}`,
      },
      body: JSON.stringify({ ok, error }),
    });
  } catch (e) {
    log('command_ack_failed', { commandId, err: String(e).slice(0, 200) });
  }
}

// ---- popup messaging --------------------------------------------------------

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (!msg || !msg.kind) return;

  switch (msg.kind) {
    case 'popup_status':
      sendResponse({
        ok: true,
        status: {
          hasKey:        !!STATE.apiKey,
          ingestUrl:     INGEST_URL,
          ingestDisabled: INGEST_DISABLED,
          queueDepth:    STATE.queue.length,
          gatewaysOpen:  STATE.gatewaysOpen.size,
          framesSeen:    STATE.framesSeen,
          flushes:       STATE.flushes,
          lastFrameAt:   STATE.lastFrameAt,
          lastFlushAt:   STATE.lastFlushAt,
          lastFlushOk:   STATE.lastFlushOk,
          lastError:     STATE.lastError,
          profileId:     STATE.profileId,
          bridgeCount:   STATE.bridges.size,
          extVersion:    chrome.runtime.getManifest().version,
        },
      });
      return true;

    case 'popup_set_key':
      STATE.apiKey = msg.apiKey || null;
      chrome.storage.local.set({ apiKey: STATE.apiKey }).then(() => sendResponse({ ok: true }));
      return true;

    case 'popup_flush':
      scheduleFlush(0);
      sendResponse({ ok: true });
      return true;

    case 'popup_selftest_ingest': {
      // Send a synthetic session_event straight to ingest, bypassing the hook.
      enqueueSession('selftest_ingest', null, `pid=${STATE.profileId}`);
      scheduleFlush(0);
      sendResponse({ ok: true });
      return true;
    }

    case 'popup_hook_test': {
      // Ask one bridge to emit a synthetic MESSAGE_CREATE that round-trips
      // through MAIN -> bridge -> SW.
      const port = STATE.bridges.values().next().value;
      if (!port) { sendResponse({ ok: false, error: 'no_bridges' }); return true; }
      try {
        port.postMessage({ kind: 'selftest_emit', payload: { ts: Date.now() } });
        sendResponse({ ok: true });
      } catch (e) {
        sendResponse({ ok: false, error: String(e).slice(0, 200) });
      }
      return true;
    }
  }
});

// ---- utils ------------------------------------------------------------------

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function log(event, attrs) {
  // SW console (chrome://extensions -> click "Service worker" under this extension).
  try { console.log(`[capture] ${event}`, attrs ?? ''); } catch (_) {}
}
