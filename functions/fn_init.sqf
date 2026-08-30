// SPDX-License-Identifier: MIT
/*
    Wire a CT_WEBBROWSER control up as a two-way channel.

    Four directions:
      SQF -> page  push   [_ctrl, "chan", value]  call webui_fnc_push
      page -> SQF  call   WEBUI.call("name", [args])
      SQF -> page  call   [_ctrl, "name", [args]] call webui_fnc_call
      page -> SQF  bool   WEBUI.ask("name", [args])

    TWO PRECONDITIONS, BOTH SILENT ON FAILURE:
      1. The page must be served from a path in
         CfgCommands::allowedHTMLLoadURIs. Otherwise the document gets no
         A3API binding and can never call back, while rendering perfectly.
      2. A "JSDialog" handler must be attached, which this does. Without one
         SendAlert succeeds on the page side and goes nowhere.

    Wire format is JSON via toJSON/fromJSON, base64'd toward the page because
    the payload is interpolated into JavaScript source.

      page -> SQF   ["CALL",  <id>, "<name>", [args]]
                    ["ASK",         "<name>", [args]]
                    ["REPLY", <id>, <ok>, <value>]
      SQF -> page   WEBUI._resolve(<id>, <ok>, '<b64>')
                    WEBUI._emit('<channel>', '<b64>')
                    WEBUI._invoke(<id>, '<name>', '<b64>')

    Handler names are per control, so a page reaches only what was registered
    for it. That is a convenience boundary, NOT a trust boundary: anyone who
    can run JavaScript in the page can call every name with arbitrary args.
    Validate server-side.

    Usage:  [_ctrl] call webui_fnc_init;
*/

params [["_ctrl", controlNull, [controlNull]]];
if (isNull _ctrl) exitWith { diag_log "[WEBUI] init: null control"; false };

_ctrl setVariable ["webui_api",   createHashMap];  // name -> handler code
_ctrl setVariable ["webui_ready", false];          // has the PAGE loaded?
_ctrl setVariable ["webui_bridge", false];         // is window.WEBUI PROVEN to exist?
_ctrl setVariable ["webui_bridgeAt", nil];         // when it was proven (not when the page loaded)
_ctrl setVariable ["webui_queue", []];             // ExecJS held until it has
_ctrl setVariable ["webui_js",    createHashMap];  // SQF -> JS call id -> [ok, [value]] (boxed: [] == null)
_ctrl setVariable ["webui_jsLive", createHashMap];  // ids still being waited on by webui_fnc_call
_ctrl setVariable ["webui_jsSeq", 0];
_ctrl setVariable ["webui_initAt", diag_tickTime];   // for the readiness delta

// published so web_prompt_overlay.hpp and webui_fnc_prompt can resolve the
// hosting display without hardcoding an idd
uiNamespace setVariable ["WEBUI_ctrl", _ctrl];

// ---------------------------------------------------------------- mission root
// RequestTexture searches the GAME filesystem, so mission-relative paths
// resolve to nothing. WEBUI.texture() retries under this prefix. Base64'd
// because the path is about to become a JavaScript string literal.
private _root = getMissionPath "";
diag_log format ["[WEBUI] mission root: %1", _root];
[_ctrl, format ["window.WEBUI && WEBUI._setRoot('%1');",
    _ctrl ctrlWebBrowserAction ["ToBase64", _root]]] call webui_fnc_exec;

// ---------------------------------------------------------- default handlers
// A page cannot write to the RPT and its console errors go nowhere by default,
// so give every page a way to say something that survives the session.
[_ctrl, "log", {
    params [["_msg", "", [""]]];
    diag_log format ["[WEBUI-PAGE] %1", _msg];
    createHashMapFromArray [["ok", true], ["msg", ""]]
}] call webui_fnc_on;

[_ctrl, "ping",       { params [["_echo", "", [""]]]; format ["pong:%1", _echo] }] call webui_fnc_on;
[_ctrl, "playerInfo", { [name player, getPlayerUID player, str (side player)] }]   call webui_fnc_on;
[_ctrl, "serverTime", { [round dayTime, round serverTime] }]                       call webui_fnc_on;
[_ctrl, "screenSize", { getResolution select [0, 2] }]                             call webui_fnc_on;
// Which control is this page in? A page cannot know its own idc, and every
// diagnostic that wanted to show it had to wait for SQF to volunteer it.
[_ctrl, "ctrlInfo",   { [ctrlIDC _webuiCtrl, ctrlPosition _webuiCtrl] }]           call webui_fnc_on;

// Native text entry. Pages cannot read their own <input> fields, so this is the
// only way to get typed text out of a web UI screen. Blocks until the player
// confirms or cancels; returns nil on cancel.
[_ctrl, "promptText", {
    params [["_title","Enter text",[""]], ["_prefill","",[""]], ["_max",64,[0]]];
    // Pass the control this handler fired on, so the overlay is resolved from
    // the dialog whose page asked -- not from whichever control happened to
    // initialise last.
    [_title, _prefill, _max, _webuiCtrl] call webui_fnc_prompt
}] call webui_fnc_on;

// ------------------------------------------------------------ response path
private _respond = {
    params ["_c", "_seq", "_ok", "_payload"];
    if (isNull _c) exitWith {};
    // toJSON REFUSES a bare nil ("can only be passed as a member of an Array or
    // HashMap"), and a nil return is not exotic here -- webui_fnc_prompt
    // returns nil on every cancel.
    private _json = "null";
    if (!isNil "_payload") then {
        _json = toJSON _payload;
        // toJSON returns an EMPTY STRING for an unsupported top-level type
        // (Object, Code, Group, Side...) rather than failing. Sent as-is that
        // resolves the page's promise with "" instead of null, silently. Same
        // mapping fn_push makes.
        if (_json isEqualTo "") then {
            diag_log format ["[WEBUI] reply seq %1: unsupported return type (%2) -- sending null",
                _seq, typeName _payload];
            _json = "null";
        };
    };
    private _b64 = _c ctrlWebBrowserAction ["ToBase64", _json];

    // NEVER QUEUE A REPLY -- sent directly, or dropped.
    //
    // A reply is scoped to the document that asked; the queue is not. Page call
    // ids restart at 1 on every renavigation, so a reply held across a freeze
    // was drained into the NEXT document and resolved whichever call took the
    // same id -- the page got a stranger's answer, silently. Pushes keep
    // queuing: a channel value is document-independent, which is what makes
    // on()'s replay work.
    if !(_c getVariable ["webui_bridge", false]) exitWith {
        diag_log format ["[WEBUI] reply seq %1 DROPPED -- the bridge is down (frozen page?), and a reply cannot be held for a later document: its call id would collide with that document's own calls. The caller times out honestly instead.",
            _seq];
    };
    // _seq toFixed 0 for the same reason as fn_call's _id: default number
    // formatting is 6 significant figures and this lands in JavaScript source.
    _c ctrlWebBrowserAction ["ExecJS",
        format ["window.WEBUI && WEBUI._resolve(%1,%2,'%3');",
            _seq toFixed 0, ["false", "true"] select _ok, _b64]];
};
_ctrl setVariable ["webui_respond", _respond];

// --------------------------------------------------------------- readiness --
// Outbound JS is held until the page is up, because ExecJS before the page
// loads is silently dropped. Readiness has four signals, in the order they can
// arrive:
//
//   hello      the injected bridge announcing itself the instant it exists.
//              This is the one that should normally win. It does not depend on
//              the page containing any of our code, so it works for a page
//              written from the README that never added the self-boot stub.
//   message    any other inbound call, which also proves the page is up.
//   PageLoaded fires whenever the page finishes loading (CT_WEBBROWSER wiki).
//              It is attached from the dialog's onLoad, which runs AFTER the
//              browser started loading url=, so on a fast client the event can
//              land before this handler exists and be missed. That is a race,
//              not an engine rule -- an earlier version of this file recorded
//              it as "PageLoaded does NOT fire on the url= path" and built the
//              whole design on that, which is how a client-speed-dependent
//              boot delay got shipped.
//   timer      3s backstop for a page that never comes up at all.
//
// Which one actually fired is recorded, because it is the single most useful
// fact when a page is slow to populate and the only way to tell the branches
// apart from outside. webui_fnc_bootProbe reads it.
private _markReady = {
    params ["_c", ["_reinject", false], ["_signal", "unknown", [""]]];
    if (isNull _c) exitWith {};
    private _first = !(_c getVariable ["webui_ready", false]);
    _c setVariable ["webui_ready", true];
    if (_first) then {
        _c setVariable ["webui_readySignal", _signal];
        _c setVariable ["webui_readyAt", diag_tickTime];
        private _t0 = _c getVariable ["webui_initAt", diag_tickTime];
        diag_log format ["[WEBUI] ready via '%1' %2s after init (t=%3)",
            _signal, (diag_tickTime - _t0) toFixed 3, diag_tickTime toFixed 1];
    };
    // ONLY 'hello' AND 'message' PROVE window.WEBUI EXISTS. 'pageloaded' and
    // 'timer' prove the document is up and nothing more, and every queued
    // statement is guarded by `window.WEBUI && ...` -- so draining on those two
    // fired the queue into a document with no bridge, silently, and emptied it.
    // Hold instead: the injector keeps retrying, and the first HELLO drains for
    // real.
    private _proven = _signal in ["hello", "message"];
    if (_proven && { !(_c getVariable ["webui_bridge", false]) }) then {
        _c setVariable ["webui_bridge", true];
        // Stamp the moment the BRIDGE landed. webui_readyAt records when the
        // page loaded, which is a different and usually earlier instant -- so a
        // probe computing "init -> first data" from readyAt reports the page
        // load and misses exactly the boot delay it exists to catch.
        _c setVariable ["webui_bridgeAt", diag_tickTime];
        diag_log format ["[WEBUI] bridge proven via '%1' %2s after init",
            _signal, (diag_tickTime - (_c getVariable ["webui_initAt", diag_tickTime])) toFixed 3];
    };

    private _q = _c getVariable ["webui_queue", []];
    if (_q isNotEqualTo []) then {
        if (_c getVariable ["webui_bridge", false]) then {
            // resize 0, NOT a new array: webui_fnc_exec holds a reference to
            // this exact object, so swapping in a fresh one leaves any exec
            // already in flight appending to an orphan (or writing its stale
            // reference back over this one). One object, mutated in place.
            private _sent = +_q;                  // copy before clearing
            _q resize 0;
            // ONE ExecJS, not up to 200 back-to-back engine calls in a frame.
            // Each statement keeps its own try/catch so a thrower still takes
            // only itself down, as it did when they were separate calls.
            private _batch = (_sent apply {
                // Caller JS on its own line, closing brace on the next: exec
                // accepts arbitrary JS, and a trailing // comment would otherwise
                // swallow the generated }catch{} and make the whole batch a
                // SyntaxError -- losing every held statement, silently.
                format ["try{
%1
}catch(e){if(window.WEBUI)window.WEBUI.call('log',['queued ExecJS failed: '+(e&&e.message)])['catch'](function(){});}", _x]
            }) joinString ";
";
            _c ctrlWebBrowserAction ["ExecJS", _batch];
            diag_log format ["[WEBUI] drained %1 queued ExecJS in one batch via '%2' (t=%3)",
                count _sent, _signal, diag_tickTime toFixed 1];
        } else {
            diag_log format ["[WEBUI] HOLDING %1 queued ExecJS -- '%2' does not prove window.WEBUI exists yet (t=%3)",
                count _q, _signal, diag_tickTime toFixed 1];
        };
    };
    // once per session, off the readiness path so it costs the first paint
    // nothing: is this client's frame delivery clamped? (FINDINGS section 1 --
    // launch path). Caches, opt-out flag, and the mission-visible hook all
    // live in fn_clampCheck; calling it twice is free by design.
    [_c] call webui_fnc_clampCheck;

    // ---------------------------------------------------------------------
    // RE-INJECTION GOES LAST, AND THAT ORDERING IS THE WHOLE POINT.
    //
    // This used to be the FIRST thing in this function, ahead of the readiness
    // marking. loadFile is refused in this context -- every page open logs
    // "Trying to execute a disabled command 'loadfile'" -- and a refusal does
    // not return "": it ABORTS the calling script at that line, and it is NOT
    // catchable (a try/catch around it was measured across three page opens and
    // five refusals and never fired once). Running unscheduled inside the
    // PageLoaded handler, that abort killed the handler before it could mark
    // readiness or drain anything.
    //
    // The consequence was invisible and total: across seven measured page opens
    // on two builds, 'pageloaded' has NEVER ONCE won the readiness race, because
    // the handler destroyed itself at its own first statement every single time.
    // That is the true origin of this file's founding belief that "PageLoaded
    // does NOT fire when the page came from the control's url= attribute". The
    // event fires exactly as the wiki says. The handler aborted.
    //
    // Nothing may be placed after this block. Anything that must run has to run
    // above it, because this line can terminate the handler without warning.
    // The page's own A3API.RequestFile stub does not touch loadFile and is the
    // only delivery path that is actually dependable (INSTALL.md step 6).
    if (_reinject) then {
        private _path = missionNamespace getVariable ["WEBUI_jsPath", "ui\html\webui.js"];
        diag_log format ["[WEBUI] reinject: loadFile '%1' (may abort here -- see FINDINGS 11)", _path];
        private _js = loadFile _path;
        diag_log format ["[WEBUI] reinject: got %1 bytes", count _js];
        if (_js isNotEqualTo "") then { _c ctrlWebBrowserAction ["ExecJS", _js]; };
    };
};
_ctrl setVariable ["webui_markReady", _markReady];

_ctrl ctrlAddEventHandler ["PageLoaded", {
    params ["_c"];
    [_c, true, "pageloaded"] call (_c getVariable ["webui_markReady", {}]);
}];

// last resort: the page has certainly painted by now even if it never talks to us
[_ctrl, _markReady] spawn {
    params ["_ctrl", "_markReady"];
    uiSleep 3;
    if (isNull _ctrl) exitWith {};
    if !(_ctrl getVariable ["webui_ready", false]) then {
        diag_log "[WEBUI] no hello, no PageLoaded and no inbound message in 3s -- marking ready on the backstop; the queue stays HELD until the bridge announces itself";
        [_ctrl, false, "timer"] call _markReady;
    };
};

// -------------------------------------------------------------- inbound EH --
_ctrl ctrlAddEventHandler ["JSDialog", {
    params ["_control", "_isConfirm", "_message"];

    // MARKING READINESS IS THE FIRST THING THIS HANDLER DOES, AND MUST STAY THAT
    // WAY. The page just spoke to us, so it is loaded and the bridge exists --
    // that fact does not depend on the message parsing. An earlier revision moved
    // a fromJSON and a four-clause type-guard chain in front of this, to name the
    // signal precisely; a page sending '[null,1]' then compares nil with && and
    // raises a type error BEFORE the handler's Boolean return exists. Per the
    // CT_WEBBROWSER wiki the browser stays unresponsive until a reply is sent, and
    // nothing here ever sends a manual JSDialogResponse, so that wedges the page
    // permanently. Same failure class as commit 9800800. The signal label is a
    // diagnostic nicety and is patched in below, after the parse, at zero cost.
    // The signal label is decided by a PREFIX TEST ON THE RAW STRING, not by
    // parsing. `select` on a String cannot throw whatever the page sent, so the
    // mark keeps its "nothing runs before it" property while still recording the
    // right name first time (a relabel afterwards would leave the RPT's "ready
    // via" line disagreeing with the stored signal). The doubled quotes are SQF's
    // escape: this compares against the literal 8 characters ["HELLO"
    // Gated on webui_BRIDGE, not webui_ready. Gating on readiness meant that
    // once 'pageloaded' or the 3s timer had marked the page ready, this branch
    // never ran again -- so the HELLO that finally proved the bridge existed
    // was ignored and the held queue was never drained.
    if !(_control getVariable ["webui_bridge", false]) then {
        private _sig = if ((_message select [0, 8]) isEqualTo "[""HELLO""") then { "hello" } else { "message" };
        [_control, false, _sig] call (_control getVariable ["webui_markReady", {}]);
    };

    private _api = _control getVariable ["webui_api", createHashMap];

    // fromJSON returns nil rather than throwing on malformed input, unlike
    // parseSimpleArray -- an uncaught throw here used to kill the handler before
    // it could reply, which looked exactly like "JSDialog never fires".
    private _req = fromJSON _message;

    if (isNil "_req" || { !(_req isEqualType []) } || { count _req < 2 }) exitWith {
        diag_log format ["[WEBUI] malformed request: %1", _message];
        true                                        // always unblock the page
    };

    // The handler's return value IS the reply to the page. A Boolean releases it;
// anything else (a Script handle from spawn) leaves the browser blocked, so
// every path assigns _out and the handler ends on it.
    private _out = true;

    switch (_req select 0) do {

        // page asked SQF a question and is waiting on a Promise
        case "CALL": {
            _req params ["", ["_seq", -1, [0]], ["_name", "", [""]], ["_args", [], [[]]]];
            private _respond = _control getVariable ["webui_respond", {}];
            private _fn = _api getOrDefault [_name, nil];
            if (isNil "_fn") then {
                diag_log format ["[WEBUI] blocked call to unregistered name '%1'", _name];
                [_control, _seq, false, format ["unknown method: %1", _name]] call _respond;
            } else {
                // The page is blocked inside alert() while this runs, so the work goes
// off-thread and the answer is delivered once the alert has been released.
                [_control, _seq, _fn, _args, _respond] spawn {
                    params ["_control", "_seq", "_fn", "_args", "_respond"];
                    private _ok = true;
                    private _res = "";
                    // `call` runs the handler in THIS scope, so a handler that
                    // needs to know which control it fired on can read
                    // _webuiCtrl. Without it the only way to find out was
                    // uiNamespace WEBUI_ctrl -- the LAST control initialised,
                    // not the calling one -- which is what every diagnostic
                    // handler used to do, so with two browser controls live
                    // their results were stamped onto the wrong one.
                    private _webuiCtrl = _control;
                    try { _res = _args call _fn; }
                    catch {
                        _ok = false; _res = str _exception;
                        diag_log format ["[WEBUI] handler threw on seq %1: %2", _seq, _exception];
                    };
                    // A handler that returns nothing does not leave _res holding
                    // nil -- SQF DELETES the variable, so the array literal below
                    // would throw "Undefined variable in expression: _res" before
                    // _respond ever got the chance to encode a null. This is the
                    // normal path, not an edge case: webui_fnc_prompt returns nil
                    // on every cancel.
                    if (isNil "_res") then {
                        [_control, _seq, _ok, nil] call _respond;
                    } else {
                        [_control, _seq, _ok, _res] call _respond;
                    };
                };
            };
        };

        // Answered by this handler's own return value, so no ExecJS leg. Runs
// unscheduled: cheap only, must not suspend.
        case "ASK": {
            _req params ["", ["_name", "", [""]], ["_args", [], [[]]]];
            private _fn = _api getOrDefault [_name, nil];
            if (isNil "_fn") then {
                diag_log format ["[WEBUI] blocked ask to unregistered name '%1'", _name];
                _out = false;
            } else {
                private _webuiCtrl = _control;   // see the CALL path above
                // TIME IT. This runs UNSCHEDULED, inside the JSDialog handler,
                // while the page is blocked inside SendConfirm -- so a slow ask
                // handler does not merely delay its own answer, it freezes the
                // whole page for as long as it runs. The docstring says "cheap
                // only, must not suspend" and nothing enforced it, so the cost
                // was invisible and showed up as "the UI is janky".
                private _t0 = diag_tickTime;
                try { _out = _args call _fn; } catch { _out = false; };
                private _ms = (diag_tickTime - _t0) * 1000;
                // diag_tickTime is single precision and coarsens with uptime
                // (BIKI), so a fixed 5 ms trip point eventually reports
                // quantisation as slowness. Require two of the clock's own
                // quanta too. float32 mantissa is 24 bits, so the step is
                // 2^(exponent-23).
                private _quantumMs = (2 ^ ((floor (ln (diag_tickTime max 1) / ln 2)) - 23)) * 1000;
                if (_ms > (5 max (2 * _quantumMs))) then {
                    diag_log format ["[WEBUI] SLOW ask('%1'): %2ms of BLOCKED page time. ask handlers run unscheduled and hold the page inside SendConfirm -- move anything this expensive to webui_fnc_on + WEBUI.call, which is spawned.",
                        _name, _ms toFixed 1];
                };
                // Once per session, not once per ask: past ~9h uptime the quantum
                // clears 2.5ms permanently, and an unlatched note would flood the
                // RPT with one line per ask for the rest of the session.
                if (_quantumMs > 2.5 && { isNil { missionNamespace getVariable "webui_quantumNoted" } }) then {
                    missionNamespace setVariable ["webui_quantumNoted", true];
                    diag_log format ["[WEBUI] note: diag_tickTime quantum is now %1ms (long uptime) -- ask timings below that are not meaningful",
                        _quantumMs toFixed 2];
                };
                if (isNil "_out" || { !(_out isEqualType true) }) then { _out = false };
            };
        };

        // HELLO is the only signal proving window.WEBUI is live in the document
        // talking to us now, so it is where the mission root is (re)sent. Sent
        // once at init it was lost whenever readiness came from 'pageloaded' or
        // the timer, leaving missionRoot "" and every mission-relative texture
        // failing for the life of the page. Idempotent; one ExecJS per document.
        case "HELLO": {
            private _root = getMissionPath "";
            _control ctrlWebBrowserAction ["ExecJS",
                format ["window.WEBUI && WEBUI._setRoot('%1');",
                    _control ctrlWebBrowserAction ["ToBase64", _root]]];
        };

        // the page answering a SQF -> JS call
        case "REPLY": {
            // _value is read positionally, not through params: a nil element
            // leaves a params variable private-but-undefined, so referencing it
            // raises and aborts this handler before it can reply -- and the
            // engine holds the browser unresponsive until a reply is sent. Any
            // WEBUI.handle() that acts instead of computing returns undefined,
            // so this is the normal path, not an edge case.
            _req params ["", ["_id", -1, [0]], ["_ok", false, [true]]];

            // Store only if someone is still waiting: fn_call drops the id when
            // it gives up, so a late reply is discarded rather than orphaned.
            // if/else and NOT exitWith -- inside a case block exitWith would
            // unwind past the switch and skip the `_out` that ends this handler,
            // which is the reply the engine holds the browser open for.
            // The shared malformed-input guard only enforces count >= 2, so a
            // short REPLY envelope made the `_req select 3` below index two past
            // the end -- which RAISES rather than yielding nil, killing the
            // handler before it can reply and wedging the page.
            private _hasValue = count _req > 3 && { !isNil { _req select 3 } };
            // PRESENCE, not truthiness. fn_call stores a per-call TOKEN ARRAY
            // as the map value (it verifies ownership by reading it back), so a
            // boolean test here would be applying ! to an array.
            private _live = _control getVariable ["webui_jsLive", createHashMap];
            if (isNil { _live get _id }) then {
                diag_log format ["[WEBUI] late REPLY for id %1 discarded -- nobody waiting", _id];
            } else {
                private _slot = _control getVariable ["webui_js", createHashMap];
                if (_hasValue) then {
                    _slot set [_id, [_ok, [_req select 3]]];
                } else {
                    _slot set [_id, [_ok, []]];    // [] == "the page answered with null"
                };
            };
        };

        default {
            diag_log format ["[WEBUI] unknown envelope tag: %1", _req select 0];
        };
    };

    _out
}];

// ------------------------------------------------------------ bridge inject
// Two boot paths, whichever wins: the page pulls this file itself with
// A3API.RequestFile (the self-boot stub -- see INSTALL.md, it is a required
// part of every page), or this injects it. Both are idempotent.
//
// THIS PATH IS NOT OPTIONAL AND ITS CADENCE IS NOT COSMETIC. A page written
// from the README without the stub has no other way to get the bridge, so
// whatever interval this loop uses becomes the floor on how soon ANY screen
// can show data. It used to fire three times 0.3s apart, which put that floor
// somewhere between 0.3s and 1s on every open of every screen -- felt as "the
// UI takes a second to appear", and invisible to anyone whose pages carry the
// stub, because for them the stub always won the race.
//
// So: fire immediately, then retry on a short backoff, and STOP the instant
// the bridge answers. The injected statement announces itself with HELLO, so
// "answers" arrives about one round trip (~12ms, FINDINGS 5) after a landing
// rather than whenever the page's own code happens to call something. The
// first shot at t=0 usually lands before the page can receive it (the wiki is
// explicit that ExecJS before PageLoaded may be dropped) -- that is what the
// retry is for.
//
// DO NOT QUOTE 50 ms AS THE FLOOR. That was the prediction, and FINDINGS 10
// measured it and refuted it: readiness took three attempts over 0.315 s, and
// stub-less pages came up at 0.200-0.205 s. The honest improvement is roughly
// 1.5-2x over the old ladder, not 6x. The binding constraint is WHEN THE PAGE
// BECOMES ABLE TO RECEIVE ExecJS, not the retry interval -- so shortening _wait
// below does not lower the floor, and the retired 50 ms figure must not
// reappear in a doc or a tuning decision.
diag_log format ["[WEBUI] initialised (4-way) t=%1", diag_tickTime toFixed 1];

[_ctrl] spawn {
    params ["_ctrl"];
    // ROOT-CAUSED 2026-08-28, and it is not "sometimes does not return".
    // loadFile is REFUSED in some client contexts -- the engine logs "Trying to
    // execute a disabled command 'loadfile' (1 arg)" and ABORTS the calling
    // script at that line rather than returning "". FINDINGS 9 recorded that for
    // a dedicated server; an in-game RPT showed it on a CLIENT, once per page
    // open, and on the opens where it hit, this spawn died before its first log
    // line -- which is why the injector silently did nothing and readiness fell
    // to the 3s backstop on two of four pages.
    //
    // So: log BEFORE the call, not only after. A log that only follows the call
    // cannot distinguish "never scheduled" from "died in the call", and that
    // ambiguity is what hid this for as long as it hid.
    //
    // NO try/catch. One was tried here and it is not a mistake that it is gone:
    // measured across three page opens and five refusals, it caught exactly
    // nothing. A disabled-command refusal is not a catchable SQF exception, it
    // is thread death. Leaving the catch in place would have been worse than
    // useless -- it reads as "this failure is handled" when the next maintainer
    // scans the file, and the absence of a REFUSED line would be taken as
    // evidence the call succeeded rather than evidence the script is already
    // dead. The pre-call log is the only thing that actually reports this.
    private _path = missionNamespace getVariable ["WEBUI_jsPath", "ui\html\webui.js"];
    diag_log format ["[WEBUI] inject: loadFile '%1' (may abort here -- see FINDINGS 11)", _path];
    private _js = loadFile _path;
    diag_log format ["[WEBUI] inject: webui.js %1 bytes", count _js];
    if (_js isEqualTo "") exitWith {
        diag_log "[WEBUI] inject: NO BRIDGE TO INJECT -- loadFile gave nothing.";
        diag_log "[WEBUI] inject:   Either WEBUI_jsPath is wrong, or loadFile is disabled in this";
        diag_log "[WEBUI] inject:   context. Either way this page can only boot from its own";
        diag_log "[WEBUI] inject:   A3API.RequestFile stub (INSTALL.md step 6), which does not use";
        diag_log "[WEBUI] inject:   loadFile. A page without the stub will hit the 3s backstop.";
    };

    // PREFIX stamps the boot path, SUFFIX announces arrival.
    //
    // The prefix has to run BEFORE webui.js, because webui.js reads
    // __webuiBootPath once and stores it as WEBUI.bootPath. A page's self-boot
    // stub stamps "stub" at head-parse time -- synchronously, before its
    // RequestFile has resolved and regardless of whether it ever does. So a
    // stamp written only by the stub answers "does this page CONTAIN a stub",
    // not "which path delivered the bridge", and reports "stub" for a page
    // whose stub is broken and was in fact rescued by this injector -- the
    // exact misconfiguration the diagnostic exists to catch. Stamping "sqf"
    // here makes it authoritative in both directions: if the stub won,
    // webui.js already ran and early-returns, so WEBUI.bootPath keeps "stub".
    //
    // The suffix is appended rather than merged for the same early-return
    // reason: a statement inside webui.js would not run on a re-injection, and
    // this has to answer whether the bridge is there NOW, every time.
    //
    // __webuiHello IS SET ONLY AFTER SendAlert RETURNS. Latching it first means
    // a send that is dropped or throws still marks the announcement done, and
    // every remaining retry becomes a guaranteed no-op that re-pushes the whole
    // bridge for nothing -- readiness then falls to the 3s backstop, which is
    // WORSE than the 0.3s floor this loop replaced, and the RPT blames the
    // whitelist.
    //
    // The doubled quotes are SQF's escape, not a typo: this has to reach the
    // page as A3API.SendAlert('["HELLO",1]').
    // UNCONDITIONAL, not ||=. The stub's "stub" stamp is written at head-parse,
    // before its RequestFile has resolved, so preserving it would keep believing
    // a stub that never delivered. If this injection is the one that defines
    // WEBUI then SQF delivered it, full stop; and if the stub really did win,
    // webui.js early-returns below and never re-reads this, so WEBUI.bootPath
    // keeps "stub" regardless of what is written here.
    private _hello = "window.__webuiBootPath='sqf';" + _js
        + ";(function(){try{"
        + "if(window.WEBUI&&!window.__webuiHello&&typeof A3API!=='undefined'&&A3API.SendAlert)"
        + "{A3API.SendAlert('[""HELLO"",1]');window.__webuiHello=1;}"
        + "}catch(e){}})();";

    // THE PROBE ALONE, for the later retries. The full payload above carries
    // webui.js itself -- 24 KB at the time of writing -- and this loop runs up
    // to ten times, so re-sending all of it every attempt pushed a quarter of a
    // megabyte of ExecJS at a page that had usually already received the bridge
    // and simply had not got its HELLO through. Three full attempts cover a
    // delivery failure; after that only the announcement is worth repeating,
    // and it is a couple of hundred bytes.
    private _probe = "(function(){try{"
        + "if(window.WEBUI&&!window.__webuiHello&&typeof A3API!=='undefined'&&A3API.SendAlert)"
        + "{A3API.SendAlert('[""HELLO"",1]');window.__webuiHello=1;}"
        + "}catch(e){}})();";

    private _deadline = diag_tickTime + 3;
    private _wait = 0.05;
    private _n = 0;
    private _bytes = 0;
    while { !isNull _ctrl
            && { !(_ctrl getVariable ["webui_bridge", false]) }
            && { diag_tickTime < _deadline } } do {
        private _payload = if (_n < 3) then { _hello } else { _probe };
        _ctrl ctrlWebBrowserAction ["ExecJS", _payload];
        _bytes = _bytes + count _payload;
        _n = _n + 1;
        uiSleep _wait;
        _wait = (_wait * 1.6) min 0.5;
    };

    if (isNull _ctrl) exitWith {};
    private _t0 = _ctrl getVariable ["webui_initAt", diag_tickTime];
    diag_log format ["[WEBUI] inject: %1 attempt(s), %2 KB sent, over %3s, bridge=%4 via '%5'",
        _n, (_bytes / 1024) toFixed 1, (diag_tickTime - _t0) toFixed 3,
        _ctrl getVariable ["webui_bridge", false],
        _ctrl getVariable ["webui_readySignal", "none"]];
};

true
