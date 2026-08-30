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
    // Forget the cache, exactly as the mid-sample abort below does. Without
    // this a player who opened and closed the first web screen of the mission
    // inside two seconds burned the once-per-session latch on a sample that
    // never happened, and no later page could ever retry -- so a genuinely
    // clamped client was never told.
    if (isNull _ctrl) exitWith {
        missionNamespace setVariable ["webui_clampChecked", false];
        diag_log "[WEBUI-CLAMP] aborted before sampling (control gone) -- will retry on the next page";
    };

    // Force content change: an idle sample cannot tell clamped from healthy,
    // so the page is made continuously dirty for exactly the sample window.
    // Same injected mutation as fn_drawRate -- works on any page.
    // POSITIVE CONTROL, because this verdict reaches the PLAYER. Injected
    // fire-and-forget, a null document.body or a dropped ExecJS produced an idle
    // page, a ~0.6 fps sample and a confident "clamped" telling a correctly
    // launched player to relaunch. Count the ticks and refuse to file without them.
    [_ctrl, "__clampTicks", {
        params [["_n", -1, [0]]];
        uiNamespace setVariable ["WEBUI_clampTicks", _n];
        true
    }] call webui_fnc_on;
    uiNamespace setVariable ["WEBUI_clampTicks", -1];

    _ctrl ctrlWebBrowserAction ["ExecJS",
        "(function(){ if (window.__webuiClampAnim) clearInterval(window.__webuiClampAnim);"
      + " var i = 0, b = document.body;"
      + " if (!b) { window.__webuiClampTicks = -2; return; }"
      + " window.__webuiClampTicks = 0;"
      + " window.__webuiClampSaved = [b.style.outlineStyle, b.style.outlineWidth, b.style.outlineColor];"
      + " b.style.outlineStyle = 'solid'; b.style.outlineWidth = '1px';"
      + " window.__webuiClampAnim = setInterval(function(){"
      // COUNT PAINTS WE CAN STILL CAUSE, not timer firings. The captured `b` is
      // detached the moment webui_fnc_serve rewrites the document -- the very
      // case the tick counter was added to catch -- and the interval keeps
      // firing happily against an orphan, reporting a healthy tick count for a
      // mutation nothing can see. Re-check that `b` is still the live body.
      + "   if (b !== document.body) { window.__webuiClampTicks = -3;"
      + "     clearInterval(window.__webuiClampAnim); window.__webuiClampAnim = null; return; }"
      + "   i = (i + 1) % 360; window.__webuiClampTicks++;"
      + "   b.style.outlineColor = 'hsl(' + i + ',90%,50%)';"
      + " }, 16); })();"];

    private _fps = [_ctrl, "clamp check, forced 60Hz mutation", 3] call webui_fnc_countDraws;

    private _ticks = -1;
    if (!isNull _ctrl) then {
        _ctrl ctrlWebBrowserAction ["ExecJS",
            "window.WEBUI && WEBUI.call('__clampTicks', [window.__webuiClampTicks || 0]).catch(function(){});"];
        private _tickWait = diag_tickTime + 1.5;   // ~20ms median round trip (FINDINGS 5); 1.5s is generous
        waitUntil {
            uiSleep 0.1;
            // != -1, not >= 0. The injected page code writes negative sentinels
            // of its own (-2 body was null, -3 document replaced under it), so a
            // non-negative wait sat out the full timeout on an answer that had
            // already arrived. -1 remains the "nothing came back" seed.
            (uiNamespace getVariable ["WEBUI_clampTicks", -1]) isNotEqualTo -1 || { diag_tickTime > _tickWait }
        };
        _ticks = uiNamespace getVariable ["WEBUI_clampTicks", -1];

        _ctrl ctrlWebBrowserAction ["ExecJS",
            "if (window.__webuiClampAnim) { clearInterval(window.__webuiClampAnim); window.__webuiClampAnim = null;"
          + " var s = window.__webuiClampSaved, b = document.body;"
          + " if (b && s) { b.style.outlineStyle = s[0]; b.style.outlineWidth = s[1]; b.style.outlineColor = s[2]; }"
          + " else if (b) { b.style.outlineStyle = 'none'; } }"];
        [_ctrl, "__clampTicks"] call webui_fnc_off;
    };

    if (_fps < 0) exitWith {
        // control died mid-sample, or another sampler already held the control;
        // forget the cache so the next page retries
        missionNamespace setVariable ["webui_clampChecked", false];
        diag_log "[WEBUI-CLAMP] sample aborted (control gone, or a sample was already running) -- will retry on the next page";
    };

    // A 3s window at 16ms should tick ~180 times. Without a confirmed mutation
    // the sample cannot distinguish clamped from healthy, so file NOTHING
    // rather than a guess -- an unverified "clamped" is worse than no verdict,
    // because the mission surfaces it to the player as advice.
    if (_ticks < 30) exitWith {
        missionNamespace setVariable ["webui_clampChecked", false];
        private _why = switch (true) do {
            case (_ticks isEqualTo -1): { "the page never answered -- no bridge, or WEBUI.call blocked" };
            case (_ticks isEqualTo -2): { "document.body was null when the mutation was injected" };
            case (_ticks isEqualTo -3): { "the document was replaced under it -- webui_fnc_serve?" };
            default { format ["only %1 of an expected ~180 ticks", _ticks] };
        };
        diag_log format ["[WEBUI-CLAMP] NO VERDICT: forced mutation did not run (%1), so %2 fps says nothing about frame delivery. Will retry on the next page.",
            _why, _fps toFixed 1];
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
