// SPDX-License-Identifier: MIT
/*
    fn_webExec.sqf -- run JavaScript in a page, holding it if the page is not up.

    The BIKI is explicit that before the control's PageLoaded event "the page
    might not be ready to receive JavaScript and may drop ExecJS requests".
    Dropped silently, of course. So everything that talks to a page goes through
    here: if PageLoaded has not been seen, the statement is queued and the
    PageLoaded handler in webui_fnc_init drains it.

    Usage:  [_ctrl, "console.log('hi')"] call webui_fnc_exec;
*/

params [["_ctrl", controlNull, [controlNull]], ["_js", "", [""]]];
if (isNull _ctrl) exitWith { false };
if (_js isEqualTo "") exitWith { false };

if (_ctrl getVariable ["webui_ready", false]) then {
    _ctrl ctrlWebBrowserAction ["ExecJS", _js];
} else {
    private _q = _ctrl getVariable ["webui_queue", []];
    // A page that never loads must not grow this without bound.
    if (count _q < 200) then { _q pushBack _js; _ctrl setVariable ["webui_queue", _q]; }
    else { diag_log "[WEBUI] exec queue full, dropping"; };
};
true
