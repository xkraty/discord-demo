'use strict';

const $ = (id) => document.getElementById(id);

// ---------- connection to the service worker ----------

let port = null;
function connect() {
  try {
    port = chrome.runtime.connect({ name: 'capture-sidepanel' });
  } catch (e) {
    setTimeout(connect, 500);
    return;
  }
  setDot('warn');
  port.onMessage.addListener(onMessage);
  port.onDisconnect.addListener(() => {
    port = null;
    setDot('err');
    setTimeout(connect, 500);
  });
}

function setDot(state) {
  const d = $('conn-dot');
  d.classList.remove('ok', 'warn', 'err');
  if (state) d.classList.add(state);
}

// ---------- live feed ----------

const FEED_MAX = 500;
const feed = $('feed');
let paused = false;

function fmtClock(iso) {
  const d = new Date(iso);
  if (isNaN(d)) return '--:--:--';
  return d.toLocaleTimeString('en-GB', { hour12: false }) + '.' +
         String(d.getMilliseconds()).padStart(3, '0');
}

function clampFeedSize() {
  while (feed.children.length > FEED_MAX) feed.removeChild(feed.firstChild);
}

function shouldDisplay(item) {
  if ($('f-paused').checked) return false;
  if (item.kind === 'frame') {
    if ($('f-dispatched').checked && !item.dispatched && !item.selftest) return false;
    if ($('f-dm').checked) {
      // Only items we can be sure are DM. Sessions and unknown frames pass.
      const dm = item.summary?.is_dm;
      if (dm === false) return false;
    }
  }
  return true;
}

function renderItem(item) {
  if (!shouldDisplay(item)) return;

  const el = document.createElement('div');
  el.className = 'item';

  const ts = document.createElement('span');
  ts.className = 'ts';
  ts.textContent = fmtClock(item.received_at || item.occurred_at);
  el.appendChild(ts);

  const t = document.createElement('span');
  t.className = 't';
  el.appendChild(t);

  const body = document.createElement('span');
  body.className = 'body';
  el.appendChild(body);

  if (item.kind === 'session') {
    el.classList.add('session');
    t.textContent = item.event;
    body.textContent = item.detail || '';
  } else if (item.kind === 'frame') {
    if (item.selftest) el.classList.add('selftest');
    if (!item.dispatched) el.classList.add('dropped');

    const tname = item.t || '<?>';
    t.textContent = tname;
    el.classList.add(tname.toLowerCase().replace(/[^a-z0-9]+/g, '_'));

    body.textContent = oneLine(item);
    el.title = JSON.stringify(item.summary || item.raw || {}, null, 2);
  } else if (item.kind === 'cleared') {
    feed.innerHTML = '';
    return;
  } else if (item.kind === 'replay') {
    feed.innerHTML = '';
    for (const e of item.events) renderItem(e);
    return;
  } else {
    t.textContent = item.kind || '?';
    body.textContent = JSON.stringify(item).slice(0, 200);
  }

  const wasAtBottom = feed.scrollTop + feed.clientHeight >= feed.scrollHeight - 24;
  feed.appendChild(el);
  clampFeedSize();
  if (wasAtBottom) feed.scrollTop = feed.scrollHeight;
}

function oneLine(item) {
  const s = item.summary;
  if (!s && item.raw) return `<unparseable> ${item.raw.slice(0, 200)}`;
  if (!s) return '';
  // Prefer the resolved channel name; fall back to ID short form.
  const ch = s.channel_name || (s.channel_id ? `ch:${String(s.channel_id).slice(-6)}` : '');
  switch (item.t) {
    case 'MESSAGE_CREATE':
    case 'MESSAGE_UPDATE':
      return `${ch}  @${s.author}  ${s.preview || ''}`;
    case 'MESSAGE_DELETE':
      return `${ch}  msg ${s.message_id} deleted`;
    case 'MESSAGE_ACK':
      return `${ch}  last_read ${s.message_id}  v${s.ack_version}`;
    case 'CHANNEL_CREATE':
      return `type ${s.type}  recipients ${s.recipient_count}`;
    case 'TYPING_START':
      return `user ${s.user_id}  in ${s.channel_id}`;
    case 'PRESENCE_UPDATE':
      return `user ${s.user_id}  → ${s.status}`;
    default:
      return s.keys ? `d.keys: ${s.keys.join(', ')}` : '';
  }
}

// ---------- status refresh ----------

async function refreshStatus() {
  const res = await chrome.runtime.sendMessage({ kind: 'popup_status' });
  if (!res?.ok) {
    setDot('err');
    return;
  }
  const s = res.status;
  $('ext-version').textContent  = `v${s.extVersion}`;
  $('s-gateways').textContent   = s.gatewaysOpen;
  $('s-frames').textContent     = s.framesSeen;
  $('s-queue').textContent      = s.queueDepth;
  $('s-flushes').textContent    = s.flushes;
  $('s-last-frame').textContent = fmtAgo(s.lastFrameAt);
  $('cfg-ingest').textContent   = s.ingestDisabled ? 'disabled (viewer-only)' : (s.ingestUrl || '—');
  $('cfg-profile').textContent  = s.profileId || '—';
  $('cfg-error').textContent    = s.lastError || '—';

  // Hide ingest-related chrome in viewer-only mode.
  document.body.classList.toggle('viewer-only', !!s.ingestDisabled);

  // Dot reflects overall health.
  if (s.bridgeCount > 0 && s.gatewaysOpen > 0) {
    // Capture is healthy. In viewer-only mode that's all we care about.
    if (s.ingestDisabled || s.hasKey) setDot('ok');
    else setDot('warn');  // ingest configured but no key
  } else if (s.bridgeCount === 0) {
    setDot('warn');  // no Discord tab attached yet
  } else {
    setDot('warn');
  }
}

function fmtAgo(ts) {
  if (!ts) return '—';
  const sec = Math.max(0, Math.round((Date.now() - ts) / 1000));
  if (sec < 60)    return `${sec}s`;
  if (sec < 3600)  return `${Math.round(sec / 60)}m`;
  return `${Math.round(sec / 3600)}h`;
}

// ---------- wire it up ----------

function onMessage(msg) {
  renderItem(msg);
}

document.addEventListener('DOMContentLoaded', () => {
  connect();
  refreshStatus();
  setInterval(refreshStatus, 1000);

  $('f-paused').addEventListener('change', (e) => { paused = e.target.checked; });
  $('btn-clear').addEventListener('click', () => {
    feed.innerHTML = '';
    try { port?.postMessage({ kind: 'clear_recent' }); } catch (_) {}
  });

  $('save-key').addEventListener('click', async () => {
    const key = $('api-key').value.trim();
    if (!key) return;
    await chrome.runtime.sendMessage({ kind: 'popup_set_key', apiKey: key });
    $('api-key').value = '';
    $('cfg-diag-result').textContent = 'API key saved.';
    refreshStatus();
  });

  $('flush-now').addEventListener('click', async () => {
    await chrome.runtime.sendMessage({ kind: 'popup_flush' });
    $('cfg-diag-result').textContent = 'Flush requested.';
  });

  $('selftest-ingest').addEventListener('click', async () => {
    await chrome.runtime.sendMessage({ kind: 'popup_selftest_ingest' });
    $('cfg-diag-result').textContent = 'Self-test event enqueued.';
  });

  $('hook-test').addEventListener('click', async () => {
    const r = await chrome.runtime.sendMessage({ kind: 'popup_hook_test' });
    $('cfg-diag-result').textContent = r?.ok
      ? 'Hook test emitted — should appear in the feed.'
      : `Hook test failed: ${r?.error || 'unknown'}`;
  });
});
