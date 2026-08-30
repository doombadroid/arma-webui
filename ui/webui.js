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

  /* The cap is measured in BYTES, not string length. FINDINGS 5 records that
     the 10240 figure came from ASCII payloads and that "whether the engine
     counts UTF-16 units or bytes above U+007F is untested, so non-ASCII
     payloads should assume the worst case, bytes". JSON.stringify does not
     escape non-ASCII, so msg.length under-counts by up to 3x: 4000 CJK
     characters measure 4019 by .length and 12019 as UTF-8. Guarding on
     .length therefore passed exactly the payloads that get truncated, and the
     truncation presents as the timeout this guard exists to prevent. */
  function msgSize(s) {
    if (typeof TextEncoder !== "undefined") {
      try { return new TextEncoder().encode(s).length; } catch (e) {}
    }
    return unescape(encodeURIComponent(s)).length;
  }

  // Two boot paths and SQF re-injects on every load. Without this guard a
  // second run replaces WEBUI and silently drops every WEBUI.on() handler:
  // calls keep working, pushes stop, nothing errors.
  if (window.WEBUI && window.WEBUI._v >= 2) { return; }

  var pending  = new Map();   // our call id -> {resolve, reject, timer, name}
  /* Null-prototype, not {}: a channel named for an Object.prototype member
     broke these outright. WEBUI.on("constructor", fn) threw
     "handlers[channel].push is not a function", and a throw at page boot kills
     the rest of the document's script; a push to a channel named "__proto__"
     set the prototype of `last` instead of a key, after which WEBUI.get()
     returned that value for channels nothing had ever pushed. */
  var handlers = Object.create(null);   // channel -> [fn]
  var last     = Object.create(null);   // channel -> last pushed value
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

  /* The mission root arrives asynchronously -- SQF queues _setRoot and it is
     delivered after the page announces itself -- but texture() read it
     SYNCHRONOUSLY. The ordering is fixed and unhelpful: HELLO is sent, then
     WEBUIReady resolves, then the page's ready callback runs on the next
     microtask, milliseconds BEFORE the drained _setRoot arrives. So the normal
     way to fill icons -- WEBUI.texture(...) at page boot -- always saw
     missionRoot === "", never tried the mission-root candidate, and rejected on
     a path that would have worked. The same call from a button a second later
     succeeded, which made it look intermittent.
     Wait for the root, briefly, instead of reading whatever happens to be
     there. */
  var pendingServe   = null;    // newest markup awaiting the coalesced rewrite
  var serveScheduled = false;

  var rootResolve = null;
  var rootReady = new Promise(function (r) { rootResolve = r; });
  var ROOT_WAIT = 2000;

  /* The candidate ladder, run once the root has had its chance to arrive.
     RequestTexture searches the GAME filesystem and a miss RESOLVES with a ~23
     char stub rather than rejecting, so each candidate has to be length-checked
     rather than merely awaited. */
  function textureWithRoot(path, size) {
    var tries = [path];
    var root = WEBUI.missionRoot;
    if (root && path.indexOf(root) !== 0 && !/^[\\/]/.test(path) && !/^a3[\\/]/i.test(path)) {
      tries.unshift(root + path);
    }
    return (function next(i) {
      if (i >= tries.length) {
        return Promise.reject(new Error("no texture found for " + path +
          (root ? "" : " (mission root never arrived, so the mission-relative candidate was not tried)")));
      }
      return A3API.RequestTexture(tries[i], size).then(
        function (url) {
          if (typeof url === "string" && url.length > 128) return url;
          return next(i + 1);
        },
        function () { return next(i + 1); }
      );
    })(0);
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
          var size = msgSize(msg);
          if (size > MSG_CAP) {
            throw new Error("call('" + name + "') message is " + size +
              " bytes; the engine truncates page -> SQF at " + MSG_CAP +
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
      /* call() rejects a non-array args with a TypeError; ask() used to
         stringify whatever it was given, and fn_init's params type-filter then
         substituted its [] default -- so ask("hasItem", "diamond") ran the SQF
         handler with NO arguments and returned a confident false with no error
         anywhere. Mirror call()'s check. */
      if (args !== undefined && !Array.isArray(args)) {
        return Promise.reject(new TypeError("ask('" + name + "') args must be an array"));
      }
      var msg = JSON.stringify(["ASK", String(name), args || []]);
      var size = msgSize(msg);
      if (size > MSG_CAP) {
        return Promise.reject(new Error(
          "ask('" + name + "') message is " + size +
          " bytes; the engine truncates page -> SQF at " + MSG_CAP + " (FINDINGS 5)"));
      }
      /* Bound it. SendConfirm's promise is settled by the engine, and an ask
         that is never answered -- no handler registered, the dialog closed
         under it -- simply never settles, so `await WEBUI.ask(...)` hangs the
         calling flow forever with nothing logged. call() at least rejects with
         a named error; this now does too. */
      return new Promise(function (resolve, reject) {
        var done = false;
        var timer = setTimeout(function () {
          if (done) { return; }
          done = true;
          reject(new Error("SQF timeout: ask('" + name + "')"));
        }, DEFAULT_TIMEOUT);
        A3API.SendConfirm(msg).then(
          function (v) { if (!done) { done = true; clearTimeout(timer); resolve(v); } },
          function (e) { if (!done) { done = true; clearTimeout(timer); reject(e); } }
        );
      });
    },

    /** Subscribe to a push channel. Replays the last value if one arrived early. */
    on: function (channel, fn) {
      var list = (handlers[channel] = handlers[channel] || []);
      list.push(fn);
      if (Object.prototype.hasOwnProperty.call(last, channel)) {
        try { fn(last[channel]); } catch (e) {
          report("push replay for '" + channel + "' threw: " + ((e && e.message) || e));
        }
      }
      return WEBUI;
    },

    /* on() APPENDS -- unlike handle(), and unlike webui_fnc_on on the SQF side,
       which both overwrite by name. The README recommends one page with view
       swapping, so a view that re-subscribes every time it is entered
       accumulated handlers: after five navigations every push ran render five
       times, and any WEBUI.call inside it sent five messages. There was no way
       to undo a subscription. off() is additive -- on() still returns WEBUI, so
       nothing that chained on it breaks. */
    off: function (channel, fn) {
      var list = handlers[channel];
      if (list) {
        if (fn === undefined) { handlers[channel] = []; }
        else {
          var i = list.indexOf(fn);
          if (i >= 0) { list.splice(i, 1); }
        }
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
    /* Uses the shared decoder, not a bare atob: atob yields one latin1 char per
       byte and the game sends UTF-8, so a mission path with any non-ASCII
       character became mojibake and texture()'s root-prefixed candidate could
       then never match. decode() JSON-parses when it can and returns the raw
       string otherwise, which is what a bare path is. */
    _setRoot: function (b64) {
      var v = decode(b64);
      if (typeof v === "string") {
        WEBUI.missionRoot = v;
        if (rootResolve) { rootResolve(v); rootResolve = null; }
      }
    },

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
      /* Bounded: if the root never arrives (no bridge, or SQF never sent it)
         fall through and try the bare path rather than hanging the caller. */
      return Promise.race([
        rootReady,
        new Promise(function (r) { setTimeout(function () { r(null); }, ROOT_WAIT); })
      ]).then(function () {
        return textureWithRoot(path, size);
      });
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

    /**
     * Replace this document with markup the SERVER sent (webui_fnc_serve).
     * Lets UI ship without a client repack; see that file for the whole story.
     *
     * document.open/write/close, NOT innerHTML. Scripts inserted via innerHTML
     * never execute, which would leave every page's markup correct and all of
     * its behaviour dead -- the worst failure mode available to a UI system,
     * because it looks like it worked. document.write runs them.
     *
     * The window object survives the rewrite, so WEBUI and the A3API binding
     * established at load are still here for the incoming document. That is the
     * reason this can work at all: the frame is never renavigated, so the
     * binding is never re-established (and could not be -- it comes from the
     * whitelisted load).
     *
     * Guarded, because a failed override must leave the PBO page on screen
     * rather than a half-written document.
     */
    /* COALESCED. Two _serve calls can arrive in a single drained ExecJS batch
       (the queue drain sends the whole batch as one script), and the rewrite is
       synchronous while the incoming document's own WEBUIReady.then() runs in a
       microtask. Applied back to back, the FIRST document's ready callback then
       runs after the SECOND has replaced it, registering that dead document's
       handlers into the live one's maps.
       Stashing the markup and doing the rewrite from a macrotask fixes both
       halves: only the newest payload survives, and each document gets its
       microtasks before the next rewrite can start. A later serve winning is
       also the correct semantics. */
    _serve: function (b64) {
      var html = decode(b64);
      if (typeof html !== "string" || html.length === 0) return false;
      pendingServe = html;
      if (serveScheduled) { return true; }
      serveScheduled = true;
      setTimeout(function () {
        serveScheduled = false;
        var markup = pendingServe;
        pendingServe = null;
        if (typeof markup === "string" && markup.length) { WEBUI._serveNow(markup); }
      }, 0);
      return true;
    },

    _serveNow: function (html) {
      try {
        /* Clear the outgoing document's closures first: the window survives the
           rewrite, so handlers, exposed and pending would keep running code from
           a document that no longer exists. `last` survives too and is kept --
           see below. */
        handlers = Object.create(null);
        exposed.clear();
        /* Settle in-flight calls rather than dropping them: each holds a
           resolve/reject pair and a live timer from the dying document. A
           rejection the caller can see beats a promise that never resolves. */
        pending.forEach(function (entry) {
          try { clearTimeout(entry.timer); } catch (_) {}
          try { entry.reject(new Error("document replaced by webui_fnc_serve while call('" + entry.name + "') was in flight")); } catch (_) {}
        });
        pending.clear();
        /* `last` IS DELIBERATELY KEPT. It holds plain values, not closures, and
           backs the documented "on() replays the last value on subscribe".
           Clearing it broke served pages in the ordinary case: producers push
           only on CHANGE, so a channel delivered before the override was never
           re-sent and get() returned undefined for the rest of the page. */

        document.open();
        /* Reporters go on BETWEEN open() and write(). document.open() is what
           erases event listeners "given window" (HTML spec), and the markup
           written below executes its own inline scripts immediately -- so
           re-attaching AFTER write() left exactly the served page's own boot
           errors unreported, which is the likeliest place for one to be. The
           served page's stub re-evals webui.js straight into the `_v >= 2`
           guard, so nothing else reinstates them. */
        installErrorReporters();
        document.write(html);
        document.close();
        /* RE-RESOLVE READINESS FOR THE INCOMING DOCUMENT. Backported from the
           mission this library was extracted from, where it was found the hard
           way; an independent review of the library then rediscovered the same
           defect, so it is not situational.

           The served markup carries the same mandatory self-boot stub every page
           does (INSTALL.md step 6), and document.write runs it. That stub
           installs a FRESH window.WEBUIReady and a fresh window.__webuiReady
           resolver, discarding the already-resolved promise. Its own
           RequestFile(...).then(eval) then re-enters this file and hits the
           `_v >= 2` guard at the top, returning long before the resolver call at
           the bottom -- so nothing ever settles the new promise.

           The result is the exact failure this function's comments claim to have
           avoided: markup renders perfectly, WEBUIReady.then() never fires, no
           channel is ever subscribed, and the screen sits on its placeholder
           forever. Worse, the window survives the rewrite (which is the whole
           reason _serve can work at all), so window.WEBUI is right there -- but
           the docs correctly tell pages not to poll it, leaving no escape hatch.

           So settle it here, mirroring the handshake at the end of this file. */
        if (window.__webuiReady) { window.__webuiReady(WEBUI); }
        else if (!window.WEBUIReady) { window.WEBUIReady = Promise.resolve(WEBUI); }
        WEBUI.ready = window.WEBUIReady || Promise.resolve(WEBUI);
        return true;
      } catch (e) {
        try { console.error("[WEBUI] serve failed: " + e.message); } catch (e2) {}
        return false;
      }
    },

    _emit: function (channel, b64) {
      var value = decode(b64);
      last[channel] = value;
      /* slice(): iterate a SNAPSHOT. off() (or on()) called from inside a push
         handler mutates this very array mid-forEach, which silently skips the
         following subscriber for that push. A snapshot makes a subscription
         change take effect on the NEXT push rather than corrupt the current one. */
      (handlers[channel] || []).slice().forEach(function (fn) {
        /* Report, do not just console.error. fn_init:60 states the reason `log`
           exists at all: a page cannot write to the RPT and its console errors
           go nowhere. Because the throw is caught here the window error
           reporter cannot see it either, so a subscriber that threw on every
           push left the tile blank with no trace anywhere -- and the channel
           read as "SQF isn't pushing". */
        try { fn(value); } catch (e) {
          report("push handler for '" + channel + "' threw: " + ((e && e.message) || e));
        }
      });
    },

    /** SQF -> JS call. Answers on the same alert channel with a REPLY envelope.
    The tag matters: fn_init's inbound switch has `case "REPLY"` and no other,
    so an envelope under any other tag falls to its default branch, is logged as
    unknown, never reaches the call's slot, and leaves webui_fnc_call blocking to
    its timeout -- the phantom-timeout-with-the-wrong-cause failure this file's
    reply paths were written to eliminate. */
    _invoke: function (id, name, b64args) {
      var reply = function (ok, value) {
        try {
          var msg = JSON.stringify(["REPLY", id, !!ok, ok ? value : String(value)]);
          if (msgSize(msg) > MSG_CAP) {
            msg = JSON.stringify(["REPLY", id, false,
              "handler '" + name + "' returned " + msgSize(msg) +
              " bytes; the engine truncates page -> SQF at " + MSG_CAP +
              " (FINDINGS 5) -- return less, or push it SQF -> page"]);
          }
          A3API.SendAlert(msg);
        } catch (e) {
          /* Answer anyway. JSON.stringify throws on a circular graph (a handler
             returning a tree whose nodes carry `parent`), on window, and on a
             BigInt -- and this used to swallow that into console.error and send
             NOTHING, so webui_fnc_call blocked its full timeout, logged
             "timed out", and the real cause sat in a page console that
             fn_init:60 says goes nowhere. A named error beats a phantom
             timeout. The second send is bare: if THAT throws the transport
             itself is gone and there is nothing left to say. */
          try {
            A3API.SendAlert(JSON.stringify(["REPLY", id, false,
              "handler '" + name + "' returned a value that could not be " +
              "serialised: " + ((e && e.message) || e)]));
          } catch (e2) { report("WEBUI._invoke could not reply at all: " + ((e2 && e2.message) || e2)); }
        }
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
  /* Both reporters MUST swallow their own rejection. call() returns a promise,
     so try/catch alone caught nothing: a rejected log call became an unhandled
     rejection, which re-entered the listener below, which logged again, which
     rejected again. With a bridge present that is a permanent 10 s loop holding
     a pending entry and a live timer each cycle; with no A3API binding call()
     rejects synchronously and it becomes a full-speed spin that the in-process
     browser thread never recovers from. */
  function report(text) {
    // The catch is the whole fix: with the rejection handled there is no
    // unhandled rejection left to re-enter the listener, so the loop cannot
    // start. Errors unrelated to reporting still get through.
    try {
      WEBUI.call("log", [text])["catch"](function () {});
    } catch (_) {}
  }
  /* Named and re-callable because _serve's document.open() erases window
     listeners and has to put them back. */
  function installErrorReporters() {
    window.addEventListener("error", onPageError);
    window.addEventListener("unhandledrejection", onPageRejection);
  }
  function onPageError(e) {
    var where = (e.filename || "page") + ":" + (e.lineno || "?") + ":" + (e.colno || "?");
    report("JS ERROR " + (e.message || e.type) + "  at " + where);
  }
  function onPageRejection(e) {
    var r = e.reason;
    report("JS UNHANDLED REJECTION " + ((r && (r.stack || r.message)) || String(r)));
  }
  installErrorReporters();

  /* Which boot path actually won, and when. Recorded because the two paths have
     very different timing and nothing else can tell them apart from inside the
     page.

     BOTH paths stamp __webuiBootPath before this file runs -- the page's stub
     writes "stub" at head-parse time, and SQF's injector prefixes "sqf" ahead of
     the payload (fn_init). So an ABSENT stamp does not mean SQF delivered it; it
     means NEITHER stamped it, which is a stub written before the stamp existed.
     The earlier version of this comment said the opposite, and the "sqf" default
     it justified accused working stubs of being broken -- see the block below
     and FINDINGS 11, where SQF's loadFile was measurably refused and the stub
     carried the whole boot while the tool still reported "sqf".
     webui_fnc_bootProbe reads both; see docs/FINDINGS.md section 10 and
     INSTALL.md step 6. */
  // "unstamped", NOT "sqf". An unknown must never be reported as a specific
  // answer, and least of all as the alarming one.
  //
  // The stamp is written by the page's self-boot stub (before it evals this
  // file) and by SQF's injector (as a prefix ahead of it). A page whose stub
  // predates the stamp -- which is every page written before 2026-08-29,
  // including every page a third party already has installed -- carries no
  // stamp at all, and defaulting that to "sqf" accused a perfectly good stub of
  // not working. It did exactly that on the mission this library came from:
  // measured, the SQF injector's loadFile was REFUSED on the very open being
  // reported, so the stub was demonstrably the only thing that could have
  // delivered the bridge, and the diagnostic still said "sqf" and told the
  // reader to go fix their stub.
  //
  // Missing data has to look like missing data, or it gets acted on.
  WEBUI.bootPath = window.__webuiBootPath || "unstamped";
  WEBUI.bootAt   = (typeof performance !== "undefined" && performance.now)
    ? performance.now() : 0;

  window.WEBUI = WEBUI;

  /* ANNOUNCE ARRIVAL. This is what tells SQF the bridge is up, and it lives here
     -- in the file itself -- rather than only in the statement SQF appends when
     it injects, because the two delivery paths are not equally reliable.

     SQF's injector reaches this file with loadFile, which is REFUSED in some
     client contexts and aborts the calling thread uncatchably (FINDINGS 11): it
     failed on two of three measured page opens. The page's own self-boot stub
     reaches it with A3API.RequestFile, which is not affected. So announcing from
     inside the file makes readiness depend on the path that works, instead of
     the one that does not.

     It matters most for a page that never calls SQF at all. A pure display
     screen -- one that only subscribes, or not even that -- has nothing to say,
     so the "any inbound message" signal can never fire for it. Measured: such a
     page sat on the 3 second backstop on every open, while its bridge had in
     fact been live within a few hundred ms the whole time.

     SQF still appends the same announcement after this file when it injects,
     and that is not redundant: on a re-injection the guard at the top of this
     IIFE returns early and nothing in here runs at all.

     __webuiHello is set only AFTER SendAlert returns, so a send that is dropped
     or throws leaves the next attempt free to try again. */
  try {
    if (!window.__webuiHello && typeof A3API !== "undefined" && A3API.SendAlert) {
      A3API.SendAlert('["HELLO",1]');
      window.__webuiHello = 1;
    }
  } catch (e) { /* no bridge to announce to; SQF's timer backstop covers it */ }

  // Resolve the readiness promise for anything that asked before we existed.
  // window.WEBUIReady is set by the page's self-boot stub; if SQF injection won the
  // race instead, create it already-resolved so awaiting it is still correct.
  if (window.__webuiReady) { window.__webuiReady(WEBUI); }
  else if (!window.WEBUIReady) { window.WEBUIReady = Promise.resolve(WEBUI); }
  WEBUI.ready = window.WEBUIReady || Promise.resolve(WEBUI);
})();
