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

diag_log format ["[WEBUI-DIAG] armed -- open a page now (waiting up to %1s)", _wait];
private _deadline = diag_tickTime + _wait;
private _ctrl = controlNull;
waitUntil {
    uiSleep 0.5;
    _ctrl = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
    !isNull _ctrl || { diag_tickTime > _deadline }
};

if (isNull _ctrl) exitWith { diag_log "[WEBUI-DIAG] timed out, no page was opened"; controlNull };
diag_log "[WEBUI-DIAG] page is up, letting it settle";
uiSleep _settle;
_ctrl
