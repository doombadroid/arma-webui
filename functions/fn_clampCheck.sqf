// SPDX-License-Identifier: MIT
/*
    fn_clampCheck.sqf -- is this client's browser frame delivery clamped?

    WHY THIS EXISTS. FINDINGS §1: frame delivery only runs when the game was
    launched through Steam, because it rides the overlay hook. Documented as
    developer advice, that finding does nothing for the PLAYER who launched
    from a shortcut or a mod manager, sees every web screen at ~1 fps, and
    reports the mission as broken. Detection belongs in the library. The wrong
    belief this file corrects is the obvious implementation: "sample the idle
    draw rate and compare" -- idle reads ~0.6 fps on a HEALTHY client too,
    because delivery is dirty-driven and a static page correctly costs
    nothing. An idle sample cannot distinguish the two worlds.

    WHAT IT DOES. Forces continuous content change -- the same injected 60 Hz
    style mutation fn_drawRate uses, which needs no cooperation from the page
    -- samples the Draw rate with webui_fnc_countDraws, cleans the injection
    up, and files a verdict. Runs ONCE per session (cached in
    missionNamespace), spawned off the readiness path so it never touches the
    first paint, and presents nothing itself: the mission decides what a
    clamped verdict looks like.

      missionNamespace getVariable "webui_clampVerdict"   "healthy"|"clamped"
      missionNamespace getVariable "webui_clampFps"       measured rate (fps)
      missionNamespace getVariable "webui_onClampVerdict" optional CODE the
          mission sets BEFORE init; called with [verdict, fps] when done
      missionNamespace setVariable ["webui_clampCheckDisabled", true]
          before init to opt out entirely

    Usage:  [_ctrl] call webui_fnc_clampCheck;   // fn_init does this for you
*/

params [["_ctrl", controlNull, [controlNull]]];
if (isNull _ctrl) exitWith {};

// opt-out and the once-per-session cache. The flag is set BEFORE the spawn so
// a readiness path that fires more than once (PageLoaded refires on reload)
// cannot double-arm the sampler.
if (missionNamespace getVariable ["webui_clampCheckDisabled", false]) exitWith {};
if (missionNamespace getVariable ["webui_clampChecked", false]) exitWith {};
missionNamespace setVariable ["webui_clampChecked", true];

[_ctrl] spawn {
    params ["_ctrl"];

    // THE THRESHOLD. Two measured worlds (FINDINGS §1), same page, same
    // machine: clamped delivery tops out around 1.9 fps even under a forced
    // 60 Hz mutation; healthy delivery floors around 20 fps (animated GIF)
    // and reaches ~61 (rAF). 8 sits more than 4x above everything a clamped
    // client can produce and at least 2x below anything a healthy one does,
    // so a misclassification needs a multiple-fold measurement error, not a
    // bad frame.
    private _CLAMP_HEALTHY_MIN = 8;

    // let the first paint and the readiness drain finish before adding load
    uiSleep 2;
    if (isNull _ctrl) exitWith {};

    // Force content change: an idle sample cannot tell clamped from healthy,
    // so the page is made continuously dirty for exactly the sample window.
    // Same injected mutation as fn_drawRate -- works on any page.
    _ctrl ctrlWebBrowserAction ["ExecJS",
        "(function(){ if (window.__webuiClampAnim) clearInterval(window.__webuiClampAnim);"
      + " var i = 0, b = document.body;"
      + " b.style.outlineStyle = 'solid'; b.style.outlineWidth = '1px';"
      + " window.__webuiClampAnim = setInterval(function(){"
      + "   i = (i + 1) % 360; b.style.outlineColor = 'hsl(' + i + ',90%,50%)';"
      + " }, 16); })();"];

    private _fps = [_ctrl, "clamp check, forced 60Hz mutation", 3] call webui_fnc_countDraws;

    if (!isNull _ctrl) then {
        _ctrl ctrlWebBrowserAction ["ExecJS",
            "if (window.__webuiClampAnim) { clearInterval(window.__webuiClampAnim);"
          + " window.__webuiClampAnim = null; document.body.style.outlineStyle = 'none'; }"];
    };

    if (_fps < 0) exitWith {
        // control died mid-sample; forget the cache so the next page retries
        missionNamespace setVariable ["webui_clampChecked", false];
        diag_log "[WEBUI-CLAMP] sample aborted (control gone) -- will retry on the next page";
    };

    private _verdict = if (_fps < _CLAMP_HEALTHY_MIN) then { "clamped" } else { "healthy" };
    missionNamespace setVariable ["webui_clampVerdict", _verdict];
    missionNamespace setVariable ["webui_clampFps", _fps];
    diag_log format ["[WEBUI-CLAMP] verdict=%1 forcedRate=%2fps threshold=%3 -- see docs/FINDINGS.md section 1",
        _verdict, _fps toFixed 1, _CLAMP_HEALTHY_MIN];

    // the mission decides what to do with it -- chat line, dialog, or nothing.
    // The library never presents.
    private _hook = missionNamespace getVariable ["webui_onClampVerdict", {}];
    [_verdict, _fps] call _hook;
};
