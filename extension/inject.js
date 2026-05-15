// MAIN-world content script. Runs at document_start in the page's JS realm,
// BEFORE any of Discord's bundle. Replaces window.WebSocket with a class that
// transparently delegates to the real WebSocket but mirrors gateway frames to
// the ISOLATED-world bridge via window.postMessage.
//
// v1: receives-only. Does not capture outbound send() calls. Does accept
// commands from the bridge to send ACK frames on the active gateway socket.
//
// Pako is bundled in by build.sh (prepended to this file).

(function () {
  'use strict';

  const TAG     = '__discord_capture__';
  const CMD_TAG = TAG + '/cmd';
  const GATEWAY_RE = /\bgateway\.discord\.gg\b/;
  const RealWS = window.WebSocket;
  const pako   = window.pako || null;

  if (!pako) {
    // Non-fatal — text frames still work. Binary frames will produce
    // decompress_error session events and be skipped.
    console.warn('[discord-capture] pako not present; binary frame decompression disabled');
  }

  let nextWsId = 1;
  const activeGateways = new Map();   // wsId -> HookedWS
  const allCtorUrls = [];             // every WebSocket URL constructed
  const debugCounts = {
    ctor: 0, msg: 0, msgGateway: 0, msgText: 0, msgBinary: 0, msgOther: 0,
    inflatePushed: 0, inflateGrew: 0, parseOk: 0, parseFail: 0,
  };
  const lastSamples = { firstBytes: null, lastBytes: null, lastChunkLen: 0 };
  const firstChunkHex = {};           // capId -> hex of first chunk seen
  const pushLog = [];                 // last 30 pako pushes, with full diag

  function post(kind, payload) {
    window.postMessage({ source: TAG, kind, payload }, '*');
  }

  // Expose minimal debug surface on the page so we can introspect from DevTools.
  window.__discordCaptureDebug = () => ({
    counts: { ...debugCounts },
    allCtorUrls: allCtorUrls.slice(),
    activeGateways: [...activeGateways.values()].map((ws) => ({
      capId: ws._capId,
      readyState: ws.readyState,
      url: ws.url,
      hasInflater: !!ws._inflater,
      inflaterErr: ws._inflater?.err ?? null,
      inflaterMsg: ws._inflater?.msg ?? null,
      pendingOutChunks: ws._inflateOut?.bytes?.length ?? 0,
      tailLen: ws._textTail?.length ?? 0,
      firstChunkHex: firstChunkHex[ws._capId] || null,
    })),
    samples: { ...lastSamples },
    pushLog: pushLog.slice(),
    pakoPresent: !!pako,
    pakoInflateProto: typeof pako?.Inflate?.prototype?.push,
    hookInstalled: window.WebSocket !== RealWS,
    documentReadyState: document.readyState,
  });

  // Note: pako's `to: 'string'` mode silently buffers in MV3 content scripts
  // and never emits — even with Z_SYNC_FLUSH. We use byte-mode and decode
  // ourselves. Per-chunk emission happens via the inflater's `onData` callback,
  // which fires for every internal output chunk regardless of high-level flush
  // state. We accumulate emitted bytes per inflater instance.
  function makeInflater(holder) {
    // Small chunkSize is intentional: pako emits via onData when its internal
    // output buffer fills. A 64KB buffer hides every Discord message smaller
    // than 64KB until much later. 1KB makes small message frames flush eagerly
    // while remaining efficient for the initial READY burst.
    const inf = new pako.Inflate({ chunkSize: 1024 });
    holder.bytes = [];
    inf.onData = (chunk) => { holder.bytes.push(chunk); };
    return inf;
  }
  const TD = new TextDecoder('utf-8');

  // Splits a string into complete top-level JSON objects, returning [objects[],
  // remainder]. Tolerates concatenated JSON like '{"a":1}{"b":2}' (which is
  // what Discord's gateway emits per zlib flush). Respects strings + escapes so
  // braces inside string literals don't break the depth count.
  function splitJsonObjects(s) {
    const out = [];
    let start = -1;
    let depth = 0;
    let inStr = false;
    let escape = false;
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if (inStr) {
        if (escape) { escape = false; continue; }
        if (c === 0x5c) { escape = true; continue; }  // \
        if (c === 0x22) { inStr = false; continue; }  // "
        continue;
      }
      if (c === 0x22) { inStr = true; continue; }     // "
      if (c === 0x7b) {                                // {
        if (depth === 0) start = i;
        depth++;
      } else if (c === 0x7d) {                         // }
        depth--;
        if (depth === 0 && start >= 0) {
          out.push(s.slice(start, i + 1));
          start = -1;
        }
      }
    }
    // Remainder is everything from the last unclosed `{` onward, or the empty
    // string if we ended cleanly.
    const remainder = start >= 0 ? s.slice(start) : '';
    return { objects: out, remainder };
  }

  class HookedWS extends RealWS {
    constructor(url, protocols) {
      super(url, protocols);
      debugCounts.ctor++;
      allCtorUrls.push(String(url).slice(0, 200));
      this._capId      = nextWsId++;
      this._isGateway  = typeof url === 'string' && GATEWAY_RE.test(url);
      this._inflater   = null;
      this._inflateOut = { bytes: [] };  // accumulator written by inflater.onData
      this._textTail   = '';             // partial UTF-8 / partial JSON carry-over

      if (!this._isGateway) return;

      activeGateways.set(this._capId, this);
      this._inflater = pako ? makeInflater(this._inflateOut) : null;

      post('gateway_open', { wsId: this._capId, url });

      this.addEventListener('message', (ev) => this._onMessage(ev));
      this.addEventListener('close',   (ev) => this._onClose(ev));
      this.addEventListener('error',   ()    => post('gateway_error', { wsId: this._capId }));
    }

    _onMessage(ev) {
      debugCounts.msg++;
      if (this._isGateway) debugCounts.msgGateway++;

      const data = ev.data;

      // Text frame: post directly.
      if (typeof data === 'string') {
        debugCounts.msgText++;
        post('gateway_frame', { wsId: this._capId, text: data, ts: Date.now() });
        return;
      }

      // Binary: must be ArrayBuffer (Discord uses binaryType=arraybuffer with zlib-stream).
      // Discord sometimes sends Blob instead — convert if so.
      if (data instanceof Blob) {
        debugCounts.msgBinary++;
        data.arrayBuffer().then((buf) => this._handleBinary(buf)).catch(() => {});
        return;
      }
      if (data instanceof ArrayBuffer) {
        debugCounts.msgBinary++;
        this._handleBinary(data);
        return;
      }
      debugCounts.msgOther++;
    }

    _handleBinary(buf) {
      if (!this._inflater) return;
      try {
        const chunk = new Uint8Array(buf);

        lastSamples.lastChunkLen = chunk.length;
        lastSamples.firstBytes = Array.from(chunk.slice(0, 16))
          .map((b) => b.toString(16).padStart(2, '0')).join(' ');
        lastSamples.lastBytes = Array.from(chunk.slice(-16))
          .map((b) => b.toString(16).padStart(2, '0')).join(' ');

        if (!firstChunkHex[this._capId]) {
          firstChunkHex[this._capId] = Array.from(chunk.slice(0, 32))
            .map((b) => b.toString(16).padStart(2, '0')).join(' ');
        }

        const pushDiag = {
          n: debugCounts.inflatePushed,
          capId: this._capId,
          len: chunk.length,
          first: Array.from(chunk.slice(0, 8)).map((b) => b.toString(16).padStart(2, '0')).join(' '),
          last: Array.from(chunk.slice(-6)).map((b) => b.toString(16).padStart(2, '0')).join(' '),
        };

        // Push with Z_SYNC_FLUSH so pako emits via onData whenever a complete
        // deflate block is ready. The accumulator is in this._inflateOut.bytes.
        this._inflater.push(chunk, pako.constants?.Z_SYNC_FLUSH ?? 2);
        debugCounts.inflatePushed++;

        pushDiag.outBytes = this._inflateOut.bytes.reduce((s, c) => s + c.length, 0);
        pushDiag.err = this._inflater.err;
        pushDiag.msg = this._inflater.msg;
        pushLog.push(pushDiag);
        if (pushLog.length > 30) pushLog.shift();

        if (this._inflateOut.bytes.length === 0) return;
        debugCounts.inflateGrew++;

        // Concatenate emitted byte chunks and clear the accumulator.
        const totalLen = this._inflateOut.bytes.reduce((s, c) => s + c.length, 0);
        const merged = new Uint8Array(totalLen);
        let off = 0;
        for (const c of this._inflateOut.bytes) {
          merged.set(c, off);
          off += c.length;
        }
        this._inflateOut.bytes = [];

        // Decode emitted bytes as UTF-8 and append to any partial text we
        // were carrying forward. Then split into complete top-level JSON
        // objects — Discord can emit several concatenated per zlib flush.
        const newText = TD.decode(merged);
        const combined = this._textTail + newText;
        const { objects, remainder } = splitJsonObjects(combined);

        for (const obj of objects) {
          try {
            JSON.parse(obj);   // validate
            debugCounts.parseOk++;
            post('gateway_frame', { wsId: this._capId, text: obj, ts: Date.now() });
          } catch (_) {
            debugCounts.parseFail++;
            // Splitter said this is a complete top-level {...} but JSON.parse
            // disagrees. Drop it on the floor; record via samples.
            lastSamples.lastBytes = '[parseFail] ' + obj.slice(0, 60);
          }
        }
        this._textTail = remainder;
      } catch (e) {
        post('decompress_error', { wsId: this._capId, message: String(e).slice(0, 200) });
        this._inflater = pako ? makeInflater(this._inflateOut) : null;
        this._textTail = '';
      }
    }

    _onClose(ev) {
      activeGateways.delete(this._capId);
      post('gateway_close', {
        wsId: this._capId,
        code: ev.code,
        reason: (ev.reason || '').slice(0, 200),
        wasClean: !!ev.wasClean,
      });
    }
  }

  // Preserve static properties (CONNECTING/OPEN/CLOSING/CLOSED).
  for (const k of Object.getOwnPropertyNames(RealWS)) {
    if (k in HookedWS) continue;
    try {
      Object.defineProperty(HookedWS, k, Object.getOwnPropertyDescriptor(RealWS, k));
    } catch (_) { /* ignore non-configurable */ }
  }

  // Replace the global. instanceof checks still pass via the extends chain.
  window.WebSocket = HookedWS;

  // Receive commands from the bridge (SW → port → content.js → here).
  window.addEventListener('message', (ev) => {
    if (ev.source !== window) return;
    const m = ev.data;
    if (!m || m.source !== CMD_TAG) return;

    if (m.kind === 'send_on_gateway') {
      const { cmdId, text } = m.payload;
      // v1: address the most recently opened gateway. Multi-tab support adds
      // a wsId-targeted variant later.
      const ws = [...activeGateways.values()].pop();
      if (!ws || ws.readyState !== RealWS.OPEN) {
        post('cmd_ack', { cmdId, ok: false, error: 'no_active_gateway' });
        return;
      }
      try {
        // Call the real send via the prototype to avoid any future overrides.
        RealWS.prototype.send.call(ws, text);
        post('cmd_ack', { cmdId, ok: true });
      } catch (e) {
        post('cmd_ack', { cmdId, ok: false, error: String(e).slice(0, 200) });
      }
      return;
    }

    if (m.kind === 'selftest_emit') {
      // Synthetic frame for end-to-end hook test from the popup.
      const fake = {
        op: 0, s: 0, t: 'MESSAGE_CREATE',
        d: {
          id: 'selftest-' + Date.now(),
          channel_id: 'selftest-channel',
          author: { id: 'selftest-author', username: 'selftest', global_name: 'Self Test' },
          content: 'extension hook test',
          timestamp: new Date().toISOString(),
        },
      };
      post('gateway_frame', { wsId: 0, text: JSON.stringify(fake), ts: Date.now(), selftest: true });
      return;
    }
  }, false);
})();
