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
_ctrl setVariable ["webui_ready", false];          // has the bridge reached the page?
_ctrl setVariable ["webui_queue", []];             // ExecJS held until it has
_ctrl setVariable ["webui_js",    createHashMap];  // SQF -> JS call id -> [ok, value]
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

// Native text entry. Pages cannot read their own <input> fields, so this is the
// only way to get typed text out of a web UI screen. Blocks until the player
// confirms or cancels; returns nil on cancel.
[_ctrl, "promptText", {
    params [["_title","Enter text",[""]], ["_prefill","",[""]], ["_max",64,[0]]];
    [_title, _prefill, _max] call webui_fnc_prompt
}] call webui_fnc_on;

// ------------------------------------------------------------ response path
private _respond = {
    params ["_c", "_seq", "_ok", "_payload"];
    if (isNull _c) exitWith {};
    // toJSON REFUSES a bare nil ("can only be passed as a member of an Array or
    // HashMap"), and a nil return is not exotic here -- webui_fnc_prompt
    // returns nil on every cancel.
    private _json = "null";
    if (!isNil "_payload") then { _json = toJSON _payload; };
    private _b64 = _c ctrlWebBrowserAction ["ToBase64", _json];
    [_c, format ["window.WEBUI && WEBUI._resolve(%1,%2,'%3');",
        _seq, ["false", "true"] select _ok, _b64]] call webui_fnc_exec;
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
    private _q = _c getVariable ["webui_queue", []];
    if (_q isNotEqualTo []) then {
        _c setVariable ["webui_queue", []];
        { _c ctrlWebBrowserAction ["ExecJS", _x]; } forEach _q;
        diag_log format ["[WEBUI] drained %1 queued ExecJS via '%2' (t=%3)",
            count _q, _signal, diag_tickTime toFixed 1];
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
        diag_log "[WEBUI] no hello, no PageLoaded and no inbound message in 3s -- draining anyway";
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
    if !(_control getVariable ["webui_ready", false]) then {
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
                try { _out = _args call _fn; } catch { _out = false; };
                if (isNil "_out" || { !(_out isEqualType true) }) then { _out = false };
            };
        };

        // The bridge announcing that it exists. Carries nothing: the readiness
        // marking above is the entire point, and it has already happened.
        case "HELLO": {};

        // the page answering a SQF -> JS call
        case "REPLY": {
            _req params ["", ["_id", -1, [0]], ["_ok", false, [true]], "_value"];
            (_control getVariable ["webui_js", createHashMap]) set [_id, [_ok, _value]];
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
// retry is for, and 50ms is the new floor instead of 300ms.
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
    // every remaining retry becomes a guaranteed no-op that re-pushes 13 KB for
    // nothing -- readiness then falls to the 3s backstop, which is WORSE than
    // the 0.3s floor this loop replaced, and the RPT blames the whitelist.
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

    private _deadline = diag_tickTime + 3;
    private _wait = 0.05;
    private _n = 0;
    while { !isNull _ctrl
            && { !(_ctrl getVariable ["webui_ready", false]) }
            && { diag_tickTime < _deadline } } do {
        _ctrl ctrlWebBrowserAction ["ExecJS", _hello];
        _n = _n + 1;
        uiSleep _wait;
        _wait = (_wait * 1.6) min 0.5;
    };

    if (isNull _ctrl) exitWith {};
    private _t0 = _ctrl getVariable ["webui_initAt", diag_tickTime];
    diag_log format ["[WEBUI] inject: %1 attempt(s) over %2s, ready=%3 via '%4'",
        _n, (diag_tickTime - _t0) toFixed 3,
        _ctrl getVariable ["webui_ready", false],
        _ctrl getVariable ["webui_readySignal", "none"]];
};

true
