// SPDX-License-Identifier: MIT
/*
    fn_webCall.sqf -- call a function INSIDE the page and get its return value.

    The direction the bridge was missing. Push tells a page something; this asks
    it something. Useful for state that only the page has -- which row is
    selected, what the user typed into an in-page keypad, the measured height of
    a rendered block, whether an animation has finished.

    The page registers the function with WEBUI.handle:

        WEBUI.handle("selectedRow", () => state.selected);
        WEBUI.handle("measure", id => document.getElementById(id).offsetHeight);

    and SQF asks for it:

        private _row = [_ctrl, "selectedRow"] call webui_fnc_call;

    BLOCKS until the page answers or the timeout expires, so it must run in a
    scheduled context. A handler registered with webui_fnc_on and invoked
    through WEBUI.call IS spawned for you, so calling this from one is fine --
    but a handler invoked through WEBUI.ask is NOT: the ASK dispatch runs it
    unscheduled inside the JSDialog handler, where this function refuses (see
    its canSuspend guard) because it cannot suspend there. Returns nil on timeout or if the page handler threw; the reason is
    logged.

    Usage:  [_ctrl, "name", [args], timeout] call webui_fnc_call;
*/

params [
    ["_ctrl", controlNull, [controlNull]],
    ["_name", "",  [""]],
    ["_args", [],  [[]]],
    ["_timeout", 10, [0]]
];
if (isNull _ctrl) exitWith { diag_log "[WEBUI] webCall: null control"; nil };
if (_name isEqualTo "") exitWith { nil };

if (!canSuspend) exitWith {
    diag_log format ["[WEBUI] webCall('%1') needs a scheduled context -- spawn it", _name];
    nil
};

// The name becomes a JavaScript string literal below. Only the PAYLOAD was
// base64'd, so a name carrying an apostrophe -- format ["row_%1", _playerText]
// -- closed the literal early and the ExecJS died as a SyntaxError that the
// engine reports nowhere: the call blocked its full timeout and logged
// "timed out", naming the wrong cause. A name built from player text was also
// a direct JS-injection path into the page.
if !(_name regexMatch "^[A-Za-z_][A-Za-z0-9_.-]*$") exitWith {
    diag_log format ["[WEBUI] webCall refused '%1' -- name must match [A-Za-z_][A-Za-z0-9_.-]*", _name];
    nil
};

// CLAIM AN ID NOTHING IS AWAITING, rather than trusting the counter.
//
// The counter cannot be made atomic here: incrementing it and reading it back
// are separate statements and a scheduled script can suspend between any two,
// so two calls in the same frame can still take the same number. Scanning the
// live registry narrows that -- an id something is already waiting on is
// skipped -- but the scan is itself a check-then-set, and SQF has no
// compare-and-swap. The guarantee therefore comes from the ownership re-check
// at consumption below, which refuses to return an answer that may belong to
// another call. A detected error beats a silently wrong one.
//
// KNOWN GAP: a webui_fnc_init re-init while a call is in flight can still cross
// answers. fn_init replaces webui_js and webui_jsLive wholesale alongside the
// counter reset, so a new call draws the same id in fresh maps and the old
// call's late REPLY lands under a token the new call owns -- the consumption
// check passes and the wrong answer is returned. Re-init is the only path that
// reuses an id; otherwise they climb monotonically.
private _live = _ctrl getVariable ["webui_jsLive", createHashMap];
_ctrl setVariable ["webui_jsLive", _live];      // ensure the map is published once

private _token = [diag_tickTime, random 1e9];
private _id = (_ctrl getVariable ["webui_jsSeq", 0]) + 1;
while { !isNil { _live get _id } } do { _id = _id + 1 };
_live set [_id, _token];
_ctrl setVariable ["webui_jsSeq", _id];

private _b64 = _ctrl ctrlWebBrowserAction ["ToBase64", toJSON _args];
// _id toFixed 0: format renders numbers with 6 significant figures, so a
// long-lived session that passes 1,000,000 calls would put "1.00000e+006" into
// the JavaScript source. toFixed is documented never to use scientific notation.
private _js = format ["window.WEBUI && WEBUI._invoke(%1,'%2','%3');", _id toFixed 0, _name, _b64];
[_ctrl, _js] call webui_fnc_exec;

private _slot = _ctrl getVariable ["webui_js", createHashMap];
private _deadline = diag_tickTime + _timeout;
private "_res";                                  // declared, deliberately unassigned
waitUntil {
    _res = _slot getOrDefault [_id, nil];
    isNull _ctrl || { !isNil "_res" } || { diag_tickTime > _deadline }
};

if (isNull _ctrl) exitWith { nil };   // control gone; its variables went with it
if (isNil "_res") exitWith {
    // UNQUEUE THE INVOKE TOO. exec holds the statement when the bridge is down,
    // so tearing down only the receive side left the send side armed: a call
    // issued during a freeze timed out, was reported failed, then ran for real
    // when the resume drained the queue. find returns -1 if it was already sent.
    private _q = _ctrl getVariable ["webui_queue", []];
    private _qi = _q find _js;
    if (_qi >= 0) then {
        _q deleteAt _qi;
        diag_log format ["[WEBUI] webCall('%1') timed out -- its queued invoke was still held and has been cancelled, so it will not run on a later resume", _name];
    };

    // Stop waiting, and say so, so the reply that is still in flight is
    // DISCARDED rather than stored. Deleting the slot alone would not do it:
    // the whole point of a timeout is that the answer has not arrived yet, so
    // there is nothing to delete, and fn_init would happily create the entry a
    // moment later with nobody left to consume it -- one orphan per timed-out
    // call, for the life of the control.
    _live deleteAt _id;
    _slot deleteAt _id;
    diag_log format ["[WEBUI] webCall('%1') timed out after %2s", _name, _timeout];
    nil
};
// OWNERSHIP RE-CHECK AT CONSUMPTION. If another call overwrote our claim during
// the unclosable window described above, the answer sitting in this slot may be
// its answer, not ours. Returning it would be a silently wrong value -- the
// worst outcome available. Fail instead.
if !((_live getOrDefault [_id, []]) isEqualTo _token) then {
    _slot deleteAt _id;
    diag_log format ["[WEBUI] webCall('%1'): call id %2 was taken over by a concurrent call -- refusing to return an answer that may not be ours",
        _name, _id];
    _res = nil;
};
if (isNil "_res") exitWith { nil };

_live deleteAt _id;
_slot deleteAt _id;

// _value is boxed by the REPLY case so that a page answering null survives the
// trip: [] means null, [x] means x. See the comment on "case REPLY" in fn_init.
_res params ["_ok", ["_box", []]];
if !(_ok) exitWith {
    diag_log format ["[WEBUI] webCall('%1') failed in the page: %2",
        _name, if (_box isEqualTo []) then { "(no reason given)" } else { _box select 0 }];
    nil
};
if (_box isEqualTo []) exitWith { nil };   // the page answered null
_box select 0
