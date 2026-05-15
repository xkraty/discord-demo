// ISOLATED-world content script. Bridges between the MAIN-world hook
// (which lives in the page realm and can see window.WebSocket) and the
// service worker.
//
// MAIN -> here via window.postMessage with source: '__discord_capture__'
// here -> MAIN via window.postMessage with source: '__discord_capture__/cmd'
// here <-> SW via a long-lived chrome.runtime port named 'capture-bridge'.

(() => {
  'use strict';

  const TAG     = '__discord_capture__';
  const CMD_TAG = TAG + '/cmd';

  let port = null;
  let pingTimer = null;
  let cycleTimer = null;

  function connect() {
    try {
      port = chrome.runtime.connect({ name: 'capture-bridge' });
    } catch (e) {
      // Extension is unloaded or reloading; retry shortly.
      setTimeout(connect, 1000);
      return;
    }

    port.onMessage.addListener((msg) => {
      // SW -> MAIN: commands (send_on_gateway, selftest_emit)
      if (!msg || typeof msg.kind !== 'string') return;
      window.postMessage({ source: CMD_TAG, kind: msg.kind, payload: msg.payload }, '*');
    });

    port.onDisconnect.addListener(() => {
      port = null;
      clearTimers();
      // SW died or was reloaded. Reconnect shortly.
      setTimeout(connect, 250);
    });

    startTimers();
    // Announce ourselves so the SW can log "tab attached" and know we're alive.
    safeSend({ kind: 'hello', payload: { url: location.href, ts: Date.now() } });
  }

  function clearTimers() {
    if (pingTimer)  { clearInterval(pingTimer);  pingTimer  = null; }
    if (cycleTimer) { clearInterval(cycleTimer); cycleTimer = null; }
  }

  function startTimers() {
    clearTimers();
    // Keep the SW alive by pinging the port.
    pingTimer = setInterval(() => safeSend({ kind: 'ping', payload: { ts: Date.now() } }), 20_000);
    // Cycle the port every ~4 min to dodge Chrome's 5-minute port-lifetime cap.
    // onDisconnect handler will reconnect immediately.
    cycleTimer = setInterval(() => { try { port?.disconnect(); } catch (_) {} }, 4 * 60 * 1000);
  }

  function safeSend(msg) {
    if (!port) return false;
    try { port.postMessage(msg); return true; }
    catch (_) { port = null; clearTimers(); setTimeout(connect, 250); return false; }
  }

  // MAIN -> here: forward to SW.
  window.addEventListener('message', (ev) => {
    if (ev.source !== window) return;
    const m = ev.data;
    if (!m || m.source !== TAG || typeof m.kind !== 'string') return;
    safeSend({ kind: m.kind, payload: m.payload });
  }, false);

  connect();
})();
