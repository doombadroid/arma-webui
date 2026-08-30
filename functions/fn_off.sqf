// SPDX-License-Identifier: MIT
/*
    fn_off.sqf -- unregister a handler previously registered with webui_fnc_on.

    webui_fnc_on writes into the control's `webui_api` hashmap and there was no
    way to take an entry back out. That is fine for a mission that registers its
    verbs once at init, and wrong for anything that registers temporarily: every
    diagnostic in this library installs handlers on the operator's live page and
    used to leave them there for the rest of the page's life. webui_fnc_latencyProbe's
    `latServe` is the worst of them -- it stays callable and will allocate an
    arbitrary-size string on demand, on a page the operator has gone back to using.

    Omit _name to clear every handler on the control.

    Returns true if anything was removed.

    Usage:  [_ctrl, "latServe"] call webui_fnc_off;
            [_ctrl] call webui_fnc_off;          // all of them
*/

params [["_ctrl", controlNull, [controlNull]], ["_name", "", [""]]];
if (isNull _ctrl) exitWith { false };

private _api = _ctrl getVariable ["webui_api", createHashMap];

if (_name isEqualTo "") exitWith {
    private _had = count _api > 0;
    _ctrl setVariable ["webui_api", createHashMap];
    _had
};

private _had = _name in _api;
_api deleteAt _name;
_ctrl setVariable ["webui_api", _api];
_had
