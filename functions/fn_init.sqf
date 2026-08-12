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
_ctrl setVariable ["webui_ready", false];          // PageLoaded seen?
_ctrl setVariable ["webui_queue", []];             // ExecJS held until it has
_ctrl setVariable ["webui_js",    createHashMap];  // SQF -> JS call id -> [ok, value]
_ctrl setVariable ["webui_jsSeq", 0];

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
// loads is silently dropped. Readiness needs three signals: PageLoaded does
// NOT fire when the page came from the control's url= attribute; any inbound
// message proves the page is up and is the one that does fire; a timer covers
// a page that never calls in.
private _markReady = {
    params ["_c", ["_reinject", false]];
    if (isNull _c) exitWith {};
    if (_reinject) then {
        private _js = loadFile (missionNamespace getVariable ["WEBUI_jsPath", "ui\html\webui.js"]);
        if (_js isNotEqualTo "") then { _c ctrlWebBrowserAction ["ExecJS", _js]; };
    };
    _c setVariable ["webui_ready", true];
    private _q = _c getVariable ["webui_queue", []];
    if (_q isNotEqualTo []) then {
        _c setVariable ["webui_queue", []];
        { _c ctrlWebBrowserAction ["ExecJS", _x]; } forEach _q;
        diag_log format ["[WEBUI] drained %1 queued ExecJS", count _q];
    };
};
_ctrl setVariable ["webui_markReady", _markReady];

_ctrl ctrlAddEventHandler ["PageLoaded", {
    params ["_c"];
    [_c, true] call (_c getVariable ["webui_markReady", {}]);
}];

// signal 3: the page has certainly painted by now even if it never talks to us
[_ctrl, _markReady] spawn {
    params ["_ctrl", "_markReady"];
    uiSleep 3;
    if (isNull _ctrl) exitWith {};
    if !(_ctrl getVariable ["webui_ready", false]) then {
        diag_log "[WEBUI] no PageLoaded and no inbound message in 3s -- draining anyway";
        [_ctrl, false] call _markReady;
    };
};

// -------------------------------------------------------------- inbound EH --
_ctrl ctrlAddEventHandler ["JSDialog", {
    params ["_control", "_isConfirm", "_message"];

    // signal 2, and the only one that fires on the url= load path: the page just
    // spoke to us, so it is loaded and WEBUI exists. Anything held goes out now.
    if !(_control getVariable ["webui_ready", false]) then {
        [_control, false] call (_control getVariable ["webui_markReady", {}]);
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
// Primary boot is the page pulling this file itself with A3API.RequestFile,
// which has no race at all. The PageLoaded handler above re-injects on every
// load. This is a third net for the case where the control was already past
// PageLoaded before onLoad attached the handler; webui.js is idempotent, and
// injecting into a document that is not up is a harmless no-op.
// Best-effort third net, off the critical path: the page self-boots via
// RequestFile and PageLoaded re-injects, so a failure here must not take the
// caller down with it.
diag_log format ["[WEBUI] initialised (4-way) t=%1", diag_tickTime toFixed 1];

[_ctrl] spawn {
    params ["_ctrl"];
    // Not root-caused: this loadFile sometimes does not return, with no error.
// Harmless where it sits; instrumented so the next occurrence says which half.
    private _js = loadFile (missionNamespace getVariable ["WEBUI_jsPath", "ui\html\webui.js"]);
    diag_log format ["[WEBUI] fallback inject: webui.js %1 bytes", count _js];
    if (_js isEqualTo "") exitWith {
        diag_log "[WEBUI] fallback inject: webui.js missing from the PBO -- set WEBUI_jsPath";
    };
    for "_i" from 1 to 3 do {
        if (isNull _ctrl) exitWith {};
        _ctrl ctrlWebBrowserAction ["ExecJS", _js];
        uiSleep 0.3;
    };
    diag_log "[WEBUI] fallback inject: done";
};

true
