// SPDX-License-Identifier: MIT
/*
    fn_awaitPage.sqf -- wait for a page to be opened, then hand back its control.

    Every diagnostic needs this and none of them can open a page themselves: the
    library does not know the host mission's dialog names, and Esc both opens the
    debug console and closes any dialog, so "run this while a page is open" is
    not a thing an operator can do. Arm the diagnostic first, then open a page.

    Returns the control, or controlNull on timeout.

    Usage:  private _ctrl = [] call webui_fnc_awaitPage;
            private _ctrl = [30, 1] call webui_fnc_awaitPage;
*/
params [["_wait", 60, [0]], ["_settle", 3, [0]]];
if (!canSuspend) exitWith { diag_log "[WEBUI-DIAG] awaitPage needs a scheduled context"; controlNull };

// WAIT FOR A CHANGE, NOT FOR NON-NULL. uiNamespace WEBUI_ctrl is written by
// every webui_fnc_init and NEVER cleared, so "non-null" returned instantly
// whenever any browser control was still alive -- an RscTitles HUD overlay,
// which Esc does not close (FINDINGS 8). The operator then saw "armed -- open a
// page now", opened the screen they wanted to measure, and every sample, every
// injection and every cleanup targeted the leftover overlay instead. Every
// Draw-based probe and the cap bisect inherited it from here.
// webui_fnc_bootProbe and webui_fnc_selfTest both already do it this way.
private _before = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
if (!isNull _before) then {
    diag_log "[WEBUI-DIAG] a browser control is already live -- waiting for a NEW one, not adopting it";
};

diag_log format ["[WEBUI-DIAG] armed -- open a page now (waiting up to %1s)", _wait];
private _deadline = diag_tickTime + _wait;
private _ctrl = controlNull;
waitUntil {
    uiSleep 0.5;
    _ctrl = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
    (!isNull _ctrl && { _ctrl isNotEqualTo _before }) || { diag_tickTime > _deadline }
};

if (isNull _ctrl || { _ctrl isEqualTo _before }) exitWith {
    diag_log "[WEBUI-DIAG] timed out, no page was opened";
    controlNull
};

// Settle on READINESS FIRST, then a short fixed pause. The old code was a blind
// uiSleep _settle, which could return before the bridge existed on a slow page
// and waited pointlessly on a fast one. Readiness alone is not enough either:
// it means the bridge answered, not that the page has painted, so a probe that
// starts sampling the instant readiness lands measures the paint it caused.
// Wait for the bridge (bounded), then give it a moment to draw.
diag_log "[WEBUI-DIAG] page is up, waiting for the bridge";
private _settleBy = diag_tickTime + (_settle max 3);
waitUntil {
    uiSleep 0.1;
    isNull _ctrl
      || { _ctrl getVariable ["webui_bridge", false] }
      || { diag_tickTime > _settleBy }
};
if (isNull _ctrl) exitWith { diag_log "[WEBUI-DIAG] control went away while settling"; controlNull };
if !(_ctrl getVariable ["webui_bridge", false]) then {
    diag_log "[WEBUI-DIAG] WARNING: window.WEBUI never announced itself -- samples may be measuring a page with no bridge";
};
uiSleep 0.5;                         // let the first paint land before sampling
if (isNull _ctrl) exitWith { diag_log "[WEBUI-DIAG] control went away while settling"; controlNull };
_ctrl
