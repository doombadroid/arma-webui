// SPDX-License-Identifier: MIT
/*
    fn_countDraws.sqf -- count the control's "Draw" events over a window.

    CT_WEBBROWSER raises Draw once per browser frame, so this is the ground
    truth for whether the engine is painting the page at all -- as opposed to
    what the page believes about itself, which can differ by an order of
    magnitude. Attaches its own handler and removes it again, so callers can
    sample repeatedly without bookkeeping.

    Returns frames per second, or -1 if the control is gone.

    Usage:  private _fps = [_ctrl, "idle", 5] call webui_fnc_countDraws;
*/
params [["_ctrl", controlNull, [controlNull]], ["_label", "", [""]], ["_secs", 5, [0]]];
if (isNull _ctrl) exitWith { -1 };

_ctrl setVariable ["webui_draws", 0];
private _eh = _ctrl ctrlAddEventHandler ["Draw", {
    params ["_c"];
    _c setVariable ["webui_draws", (_c getVariable ["webui_draws", 0]) + 1];
}];

private _t0 = diag_tickTime;
uiSleep _secs;
private _elapsed = (diag_tickTime - _t0) max 0.001;
private _n = _ctrl getVariable ["webui_draws", 0];
_ctrl ctrlRemoveEventHandler ["Draw", _eh];

private _fps = _n / _elapsed;
diag_log format ["[WEBUI-DRAW] %1: %2 draws / %3s = %4 fps",
    _label, _n, _elapsed toFixed 1, _fps toFixed 1];
_fps
