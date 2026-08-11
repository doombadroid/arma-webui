// SPDX-License-Identifier: MIT
/*
    fn_paintProbe.sqf -- WHO is throttling the paint: dirty-tracking, the
    animation scheduler, or the Steam HTML surface?

    The page's own user agent says "Valve Steam Client": under Proton this
    browser is serviced by Steam's webhelper through the Steam HTML-surface
    API, not by a CEF inside Arma -- which also explains why Arma has no CEF
    child processes, why JS runs at full speed while paint sits at ~1 fps
    (Steam throttles surfaces it considers BACKGROUND), and why every
    engine-side lever did nothing: Arma is not the one painting.

    Three samples, each 5s, counting the control's Draw events:
      1. baseline
      2. an animated GIF on screen -- Chromium animates GIFs with its own
         internal controller (no CSS, no rAF, no JS timers). Draw jumping here
         means frame delivery is dirty-driven and only the animation
         schedulers are suppressed. Draw staying ~1/s means BeginFrame itself
         is clamped upstream.
      3. the STEAM OVERLAY OPEN (you press SHIFT+TAB when told) -- if Steam is
         throttling the surface as "background", foregrounding Steam's own UI
         is the most direct way to change that state from the outside.

    Arm first, then open a page:  [] spawn webui_fnc_paintProbe;
*/
if (!canSuspend) exitWith { diag_log "[WEBUI-PAINT] use spawn"; };

private _ctrl = [] call webui_fnc_awaitPage;
if (isNull _ctrl) exitWith {};
private _disp = ctrlParent _ctrl;


systemChat "paint probe: baseline 5s -- hands off";
[_ctrl, "1 baseline", 5] call webui_fnc_countDraws;

[_ctrl, "gifLoad", [true], 6] call webui_fnc_call;
systemChat "paint probe: GIF phase -- a flashing square should be bottom-right of the phone";
[_ctrl, "2 animated GIF (20fps)", 5] call webui_fnc_countDraws;
private _raf = [_ctrl, "rafRate", [], 8] call webui_fnc_call;
diag_log format ["[WEBUI-PAINT]   rAF during GIF: %1 fps", _raf];
[_ctrl, "gifLoad", [false], 6] call webui_fnc_call;

diag_log "[WEBUI-PAINT] >>> OPEN THE STEAM OVERLAY NOW (SHIFT+TAB) and leave it open <<<";
// The RPT is invisible in game -- cue on screen and with a horn instead.
playSound "noothorn";
titleText ["<t size='1.4' color='#c9e21a'>OPEN THE STEAM OVERLAY NOW (SHIFT+TAB)<br/>leave it open until the next message</t>", "PLAIN", 0.2, true, true];
systemChat ">>> OPEN THE STEAM OVERLAY NOW (SHIFT+TAB) and LEAVE IT OPEN <<<";
uiSleep 3;
[_ctrl, "3 steam overlay open", 6] call webui_fnc_countDraws;
playSound "noothorn";
titleText ["<t size='1.2' color='#33ffbb'>done -- close the overlay</t>", "PLAIN", 0.2, true, true];
systemChat "PAINT PROBE DONE -- close the overlay";
diag_log "[WEBUI-PAINT] close the overlay. done";

