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

// countDraws returns -1 for a refusal (another sample already running -- the
// automatic clamp check does exactly that at ready+2s) or a dead control. A
// probe that ignores it prints "-1.0 fps" as though it were a measurement.
private _report = {
    params ["_label", "_fps"];
    if (_fps < 0) then {
        diag_log format ["[WEBUI-DRAW] %1: NO SAMPLE (refused or control gone) -- rerun; this is not a rate", _label];
        false
    } else { true };
};

systemChat "draw rate: idle 5s, hands off";
["idle, mouse still", [_ctrl, "idle, mouse still", 5] call webui_fnc_countDraws] call _report;

systemChat ">>> MOVE THE MOUSE over the page for 5s <<<";
["mouse moving over the page", [_ctrl, "mouse moving over the page", 5] call webui_fnc_countDraws] call _report;

// Forcing content change without touching rAF separates "frames are delivered
// only when something changes" from "frames are not delivered at all". Injected
// rather than called, so this works on any page without its cooperation.
// POSITIVE CONTROL. This is the only sample that can tell clamped from healthy
// -- the idle and mouse samples cannot -- so the whole verdict rests on the
// mutation actually running. It used to be injected fire-and-forget: if
// document.body was null, or the ExecJS was dropped, or a webui_fnc_serve
// override replaced the document under the captured `b`, the interval never
// dirtied anything, the sample read ~0.6 fps, and the operator followed this
// file's own rule and went hunting the launch path on a correctly launched
// client. Count the ticks in the page and read them back.
[_ctrl, "__drawTicks", {
    params [["_n", -1, [0]]];
    uiNamespace setVariable ["WEBUI_drawTicks", _n];
    true
}] call webui_fnc_on;
uiNamespace setVariable ["WEBUI_drawTicks", -1];

_ctrl ctrlWebBrowserAction ["ExecJS",
    "(function(){ if (window.__webuiAnim) clearInterval(window.__webuiAnim);"
  + " var i = 0, b = document.body;"
  + " if (!b) { window.__webuiAnimTicks = -2; return; }"
  + " window.__webuiAnimTicks = 0;"
  + " window.__webuiAnimSaved = [b.style.outlineStyle, b.style.outlineWidth, b.style.outlineColor];"
  + " b.style.outlineStyle = 'solid'; b.style.outlineWidth = '1px';"
  + " window.__webuiAnim = setInterval(function(){"
  // the captured body is detached if the document is rewritten under us; a
  // tick count from an orphan proves nothing about what is being painted
  + "   if (b !== document.body) { window.__webuiAnimTicks = -3;"
  + "     clearInterval(window.__webuiAnim); window.__webuiAnim = null; return; }"
  + "   i = (i + 1) % 360; window.__webuiAnimTicks++;"
  + "   b.style.outlineColor = 'hsl(' + i + ',90%,50%)';"
  + " }, 16); })();"];
systemChat "draw rate: a style is mutating every 16ms, hands off";
private _fpsMut = [_ctrl, "JS style mutation @60Hz", 5] call webui_fnc_countDraws;

// ask the page how many times the interval actually fired
_ctrl ctrlWebBrowserAction ["ExecJS",
    "window.WEBUI && WEBUI.call('__drawTicks', [window.__webuiAnimTicks || 0]).catch(function(){});"];
private _tickWait = diag_tickTime + 1.5;   // ~20ms median round trip (FINDINGS 5); 1.5s is generous
waitUntil {
    uiSleep 0.1;
    // != -1, not >= 0. The injected page code writes NEGATIVE sentinels of its
    // own -- -2 for "document.body was null when the mutation was injected" and
    // -3 for "the document was replaced under the mutation" -- so waiting for a
    // non-negative value sat out the full timeout on an answer that had already
    // arrived, and then reported "the page did not answer", naming the opposite
    // cause to the evidence. -1 stays the "nothing came back" seed.
    (uiNamespace getVariable ["WEBUI_drawTicks", -1]) isNotEqualTo -1 || { diag_tickTime > _tickWait }
};
private _ticks = uiNamespace getVariable ["WEBUI_drawTicks", -1];

_ctrl ctrlWebBrowserAction ["ExecJS",
    "if (window.__webuiAnim) { clearInterval(window.__webuiAnim); window.__webuiAnim = null;"
  + " var s = window.__webuiAnimSaved, b = document.body;"
  + " if (b && s) { b.style.outlineStyle = s[0]; b.style.outlineWidth = s[1]; b.style.outlineColor = s[2]; }"
  + " else if (b) { b.style.outlineStyle = 'none'; } }"];
[_ctrl, "__drawTicks"] call webui_fnc_off;

// A 5s window at 16ms should tick ~300 times. Well under that and the mutation
// was not running, so the sample says nothing about frame delivery.
// Every value the injected page code can write has a branch. -1 is the seed
// meaning "nothing came back"; -2 and -3 are written BY the page and are
// answers, not silence.
switch (true) do {
    case (_ticks isEqualTo -1): {
        diag_log "[WEBUI-DRAW] mutation tick count UNAVAILABLE (page did not answer -- no bridge, or WEBUI.call blocked). The 60Hz sample above is UNVERIFIED: do not read it as a clamp verdict.";
    };
    case (_ticks isEqualTo -2): {
        diag_log "[WEBUI-DRAW] MUTATION NEVER STARTED: document.body was null when it was injected. The 60Hz sample measured an idle page; this is NOT evidence of a clamp.";
    };
    case (_ticks isEqualTo -3): {
        diag_log "[WEBUI-DRAW] MUTATION WAS ORPHANED: the document was replaced under it (webui_fnc_serve?). The 60Hz sample is not a measurement of the live page.";
    };
    case (_ticks < 50): {
        diag_log format ["[WEBUI-DRAW] MUTATION NEVER RAN (%1 ticks in 5s, expected ~300) -- the 60Hz sample measured an idle page. This is NOT evidence of a clamp; rerun.", _ticks];
    };
    default {
        diag_log format ["[WEBUI-DRAW] mutation confirmed: %1 ticks in 5s -- the %2 fps sample above is a real measurement",
            _ticks, _fpsMut toFixed 1];
    };
};

diag_log "[WEBUI-DRAW] done";
