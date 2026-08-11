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
    scheduled context (spawn, or inside a webOn handler -- those are spawned for
    you). Returns nil on timeout or if the page handler threw; the reason is
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

private _id = (_ctrl getVariable ["webui_jsSeq", 0]) + 1;
_ctrl setVariable ["webui_jsSeq", _id];

private _b64 = _ctrl ctrlWebBrowserAction ["ToBase64", toJSON _args];
[_ctrl, format ["window.WEBUI && WEBUI._invoke(%1,'%2','%3');", _id, _name, _b64]] call webui_fnc_exec;

private _slot = _ctrl getVariable ["webui_js", createHashMap];
private _deadline = diag_tickTime + _timeout;
private "_res";                                  // declared, deliberately unassigned
waitUntil {
    _res = _slot getOrDefault [_id, nil];
    isNull _ctrl || { !isNil "_res" } || { diag_tickTime > _deadline }
};

if (isNull _ctrl) exitWith { nil };
if (isNil "_res") exitWith {
    diag_log format ["[WEBUI] webCall('%1') timed out after %2s", _name, _timeout];
    nil
};
_slot deleteAt _id;

_res params ["_ok", "_value"];
if !(_ok) exitWith {
    diag_log format ["[WEBUI] webCall('%1') failed in the page: %2", _name, _value];
    nil
};
_value
