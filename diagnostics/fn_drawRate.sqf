// SPDX-License-Identifier: MIT
/*
    fn_drawRate.sqf -- is the engine actually painting the page?

    THE FIRST THING TO RUN when a page looks frozen or its buttons feel laggy.
    A page can report itself healthy, run its JavaScript at full speed, and
    still be painted about once a second -- see docs/FINDINGS.md, where the
    cause turns out to be how the game was launched rather than anything in
    the page.

    Samples three ways: idle, under mouse movement, and while JavaScript
    mutates a style at 60Hz. If all three sit near 1 fps, the page is not being
    painted and no CSS or JS change will alter that.

    Arm first, then open a page:  [] spawn webui_fnc_drawRate;
*/
if (!canSuspend) exitWith { diag_log "[WEBUI-DRAW] use spawn"; };

private _ctrl = [] call webui_fnc_awaitPage;
if (isNull _ctrl) exitWith {};

systemChat "draw rate: idle 5s, hands off";
[_ctrl, "idle, mouse still", 5] call webui_fnc_countDraws;

systemChat ">>> MOVE THE MOUSE over the page for 5s <<<";
[_ctrl, "mouse moving over the page", 5] call webui_fnc_countDraws;

// Forcing content change without touching rAF separates "frames are delivered
// only when something changes" from "frames are not delivered at all". Injected
// rather than called, so this works on any page without its cooperation.
_ctrl ctrlWebBrowserAction ["ExecJS",
    "(function(){ if (window.__webuiAnim) clearInterval(window.__webuiAnim);"
  + " var i = 0, b = document.body;"
  + " b.style.outlineStyle = 'solid'; b.style.outlineWidth = '1px';"
  + " window.__webuiAnim = setInterval(function(){"
  + "   i = (i + 1) % 360; b.style.outlineColor = 'hsl(' + i + ',90%,50%)';"
  + " }, 16); })();"];
systemChat "draw rate: a style is mutating every 16ms, hands off";
[_ctrl, "JS style mutation @60Hz", 5] call webui_fnc_countDraws;
_ctrl ctrlWebBrowserAction ["ExecJS",
    "if (window.__webuiAnim) { clearInterval(window.__webuiAnim);"
  + " window.__webuiAnim = null; document.body.style.outlineStyle = 'none'; }"];

diag_log "[WEBUI-DRAW] done";
