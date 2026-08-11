// SPDX-License-Identifier: MIT
/*
    fn_focusProbe.sqf -- does WINDOW FOCUS feed the browser's frame clamp?

    The Steam overlay will not draw on this client (hook and Vulkan layer are
    both correctly injected -- it is the overlay UI that fails, likely the
    webhelper-rendered overlay under GE-Proton), so the overlay cannot be used
    as the lever on Steam's surface state. Focus can: alt-tabbing the game away
    and back is the strongest focus transition available from outside.

      1. baseline, focused          (5s)
      2. ALT-TABBED AWAY            (6s)  -- horn tells you when
      3. back, refocused            (6s)  -- horn again

    If draws jump in 2 or 3, surface state responds to focus and the clamp is
    negotiable. If all three read ~1 fps, focus is not the lever either.

    Arm first, then open a page:  [] spawn webui_fnc_focusProbe;
*/
if (!canSuspend) exitWith { diag_log "[WEBUI-FOCUS] use spawn"; };

private _ctrl = [] call webui_fnc_awaitPage;
if (isNull _ctrl) exitWith {};
private _disp = ctrlParent _ctrl;


systemChat "focus probe: baseline 5s -- hands off";
[_ctrl, "1 focused baseline", 5] call webui_fnc_countDraws;

playSound "noothorn";
titleText ["<t size='1.4' color='#c9e21a'>ALT-TAB AWAY FROM THE GAME NOW<br/>stay away until the next horn</t>", "PLAIN", 0.2, true, true];
systemChat ">>> ALT-TAB AWAY NOW -- stay away until the horn <<<";
uiSleep 2;
[_ctrl, "2 alt-tabbed away", 6] call webui_fnc_countDraws;

playSound "noothorn";
systemChat ">>> COME BACK to the game now <<<";
uiSleep 2;
[_ctrl, "3 back, refocused", 6] call webui_fnc_countDraws;

playSound "noothorn";
titleText ["<t size='1.2' color='#33ffbb'>focus probe done</t>", "PLAIN", 0.2, true, true];
systemChat "FOCUS PROBE DONE";
diag_log "[WEBUI-FOCUS] done";
