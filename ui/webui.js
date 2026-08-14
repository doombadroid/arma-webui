// SPDX-License-Identifier: MIT
/*
 * webui.js -- browser half of the arma-webui bridge.
 *
 * Transport (all four directions):
 *   SQF -> JS  push    ExecJS "WEBUI._emit(ch, b64)"
 *   JS  -> SQF call    A3API.SendAlert(json) -> "JSDialog" -> WEBUI._resolve
 *   SQF -> JS  call    ExecJS "WEBUI._invoke(id, name, b64)" -> SendAlert reply
 *   JS  -> SQF bool    A3API.SendConfirm(json), answered by the handler's return
 *
 * Payloads are JSON, base64'd toward the page: that payload is interpolated
 * into JavaScript source by format[], so a quote or newline in a player name
 * would break the statement or inject code. Base64 has neither.
 *
 * Boots two ways, whichever wins: the page pulls this file with
 * A3API.RequestFile, or SQF injects it. Both are idempotent.
 * window.WEBUIReady resolves once WEBUI exists.
 *
 * API
 *   WEBUI.call(name, args, timeout)  -> Promise of the SQF return
 *   WEBUI.on(channel, fn)            -> subscribe; replays the last value
 *   WEBUI.get(channel)               -> last pushed value
 *   WEBUI.handle(name, fn)           -> expose a page function to SQF
 *   WEBUI.ask(name, args)            -> Promise<bool>, one round trip
 *   WEBUI.texture(path, maxSize)     -> Promise<dataURL>
 *   WEBUI.file(path)                 -> Promise<string>
 *   WEBUI.preprocessed(path)         -> Promise<string>
 */
(function () {
  "use strict";

  // The engine truncates every page -> SQF message (SendAlert and SendConfirm
  // alike) at exactly 10240 characters, envelope included -- measured to the
  // character by webui_fnc_msgCapProbe, FINDINGS 5. A message over the cap
  // arrives as broken JSON and presents as a TIMEOUT with no cause, so both
  // senders below refuse to send one and name the real problem instead.
  var MSG_CAP = 10240;

  // Two boot paths and SQF re-injects on every load. Without this guard a
  // second run replaces WEBUI and silently drops every WEBUI.on() handler:
  // calls keep working, pushes stop, nothing errors.
  if (window.WEBUI && window.WEBUI._v >= 2) { return; }

  var pending  = new Map();   // our call id -> {resolve, reject, timer, name}
  var handlers = {};          // channel -> [fn]
  var last     = {};          // channel -> last pushed value
  var exposed  = new Map();   // name -> fn, callable from SQF
  var seq      = 1;
  var DEFAULT_TIMEOUT = 10000;

  function decode(b64) {
    var raw;
    try { raw = atob(b64); } catch (e) { return null; }
    // atob yields one latin1 char per BYTE, but the game sends UTF-8, so
    // non-ASCII arrives as mojibake without this.
    if (typeof TextDecoder !== "undefined") {
      try {
        var bytes = new Uint8Array(raw.length);
        for (var i = 0; i < raw.length; i++) { bytes[i] = raw.charCodeAt(i) & 0xff; }
        raw = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
      } catch (e) { /* not valid UTF-8 -- keep the latin1 reading */ }
    }
    try { return JSON.parse(raw); } catch (e) { return raw; }
  }

  function haveAPI() {
    return typeof A3API !== "undefined" && !!A3API.SendAlert;
  }

  var WEBUI = {
    _v: 2,

    /** Call a whitelisted SQF handler. Rejects on timeout or unknown name. */
    call: function (name, args, timeout) {
      args = args || [];
      if (!Array.isArray(args)) {
        return Promise.reject(new TypeError("args must be an Array"));
      }
      if (!haveAPI()) {
        return Promise.reject(new Error(
          "A3API unavailable -- page is not served from a whitelisted path"));
      }
      var id = seq++;
      return new Promise(function (resolve, reject) {
        var timer = setTimeout(function () {
          pending.delete(id);
          reject(new Error("SQF timeout: " + name));
        }, timeout || DEFAULT_TIMEOUT);
        pending.set(id, { resolve: resolve, reject: reject, timer: timer, name: name });
        try {
          var msg = JSON.stringify(["CALL", id, String(name), args]);
          if (msg.length > MSG_CAP) {
            throw new Error("call('" + name + "') message is " + msg.length +
              " chars; the engine truncates page -> SQF at " + MSG_CAP +
              " (FINDINGS 5) -- send less, or pull the data SQF -> page");
          }
          A3API.SendAlert(msg);
        } catch (e) {
          clearTimeout(timer);
          pending.delete(id);
          reject(e);
        }
      });
    },

    /* Resolved by the SQF handler's return value, so there is no ExecJS leg:
       ~0.7x the latency of call() (measured, FINDINGS 5), but bool only. */
    ask: function (name, args) {
      if (!haveAPI() || !A3API.SendConfirm) {
        return Promise.reject(new Error("A3API.SendConfirm unavailable"));
      }
      var msg = JSON.stringify(["ASK", String(name), args || []]);
      if (msg.length > MSG_CAP) {
        return Promise.reject(new Error(
          "ask('" + name + "') message is " + msg.length +
          " chars; the engine truncates page -> SQF at " + MSG_CAP + " (FINDINGS 5)"));
      }
      return A3API.SendConfirm(msg);
    },

    /** Subscribe to a push channel. Replays the last value if one arrived early. */
    on: function (channel, fn) {
      (handlers[channel] = handlers[channel] || []).push(fn);
      if (Object.prototype.hasOwnProperty.call(last, channel)) {
        try { fn(last[channel]); } catch (e) { console.error(e); }
      }
      return WEBUI;
    },

    get: function (channel) { return last[channel]; },

    /**
     * Expose a page function to SQF:  [_ctrl, "name", [args]] call webui_fnc_call
     * The function may return a value or a Promise; either is sent back.
     */
    handle: function (name, fn) { exposed.set(String(name), fn); return WEBUI; },

    // ---- game filesystem, straight from the page ---------------------------
    /** Mission root, pushed by webui_fnc_init. See texture() below. */
    missionRoot: "",
    _setRoot: function (b64) { try { WEBUI.missionRoot = atob(b64); } catch (e) {} },

    /**
     * A .paa as a data URL; maxSize picks the mip. RequestTexture searches the
     * GAME filesystem, and a miss RESOLVES with a ~23 char stub instead of
     * rejecting, so mission-relative paths are retried under the mission root.
     */
    texture: function (path, maxSize) {
      if (!haveAPI() || !A3API.RequestTexture) {
        return Promise.reject(new Error("A3API.RequestTexture unavailable"));
      }
      var size = maxSize || 512;
      var tries = [path];
      var root = WEBUI.missionRoot;
      if (root && path.indexOf(root) !== 0 && !/^[\\/]/.test(path) && !/^a3[\\/]/i.test(path)) {
        tries.unshift(root + path);
      }
      return (function next(i) {
        if (i >= tries.length) {
          return Promise.reject(new Error("no texture found for " + path));
        }
        return A3API.RequestTexture(tries[i], size).then(
          function (url) {
            // a failed lookup resolves with a stub, it does not reject
            if (typeof url === "string" && url.length > 128) return url;
            return next(i + 1);
          },
          function () { return next(i + 1); }
        );
      })(0);
    },
    /** Raw file out of the PBO -- same semantics as SQF loadFile. */
    file: function (path) {
      if (!haveAPI() || !A3API.RequestFile) {
        return Promise.reject(new Error("A3API.RequestFile unavailable"));
      }
      return A3API.RequestFile(path);
    },
    /** File after the Arma preprocessor -- macros and #include resolved. */
    preprocessed: function (path) {
      if (!haveAPI() || !A3API.RequestPreprocessedFile) {
        return Promise.reject(new Error("A3API.RequestPreprocessedFile unavailable"));
      }
      return A3API.RequestPreprocessedFile(path);
    },

    // ---- called from SQF via ExecJS, not from page code ---------------------
    _resolve: function (id, ok, b64) {
      var entry = pending.get(id);
      if (!entry) return;
      clearTimeout(entry.timer);
      pending.delete(id);
      var value = decode(b64);
      if (ok) entry.resolve(value); else entry.reject(new Error(String(value)));
    },

    _emit: function (channel, b64) {
      var value = decode(b64);
      last[channel] = value;
      (handlers[channel] || []).forEach(function (fn) {
        try { fn(value); } catch (e) { console.error(e); }
      });
    },

    /** SQF -> JS call. Answers on the same alert channel with a JSRESP envelope. */
    _invoke: function (id, name, b64args) {
      var reply = function (ok, value) {
        try {
          var msg = JSON.stringify(["REPLY", id, !!ok, ok ? value : String(value)]);
          if (msg.length > MSG_CAP) {
            msg = JSON.stringify(["REPLY", id, false,
              "handler '" + name + "' returned " + msg.length +
              " chars; the engine truncates page -> SQF at " + MSG_CAP +
              " (FINDINGS 5) -- return less, or push it SQF -> page"]);
          }
          A3API.SendAlert(msg);
        } catch (e) { console.error("WEBUI._invoke reply failed", e); }
      };
      var fn = exposed.get(String(name));
      if (!fn) { reply(false, "no JS handler: " + name); return; }
      var args = decode(b64args);
      if (!Array.isArray(args)) args = [];
      try {
        Promise.resolve(fn.apply(null, args)).then(
          function (v) { reply(true, v === undefined ? null : v); },
          function (e) { reply(false, e && e.message || e); }
        );
      } catch (e) { reply(false, e && e.message || e); }
    }
  };

  /* A JavaScript error kills a page silently: the document stops executing,
     handlers are never registered, and it reads as a broken feature rather
     than a crash. Report through the same channel as everything else. */
  window.addEventListener("error", function (e) {
    var where = (e.filename || "page") + ":" + (e.lineno || "?") + ":" + (e.colno || "?");
    try {
      WEBUI.call("log", ["JS ERROR " + (e.message || e.type) + "  at " + where]);
    } catch (_) {}
  });
  window.addEventListener("unhandledrejection", function (e) {
    var r = e.reason;
    try {
      WEBUI.call("log", ["JS UNHANDLED REJECTION " +
        ((r && (r.stack || r.message)) || String(r))]);
    } catch (_) {}
  });

  window.WEBUI = WEBUI;

  // Resolve the readiness promise for anything that asked before we existed.
  // window.WEBUIReady is set by the page's self-boot stub; if SQF injection won the
  // race instead, create it already-resolved so awaiting it is still correct.
  if (window.__webuiReady) { window.__webuiReady(WEBUI); }
  else if (!window.WEBUIReady) { window.WEBUIReady = Promise.resolve(WEBUI); }
  WEBUI.ready = window.WEBUIReady || Promise.resolve(WEBUI);
})();
