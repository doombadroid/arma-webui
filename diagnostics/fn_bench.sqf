// SPDX-License-Identifier: MIT
/*
    fn_webBench.sqf -- measure what the embedded browser actually costs, and what
    CSS viewport a page really gets.

    WHY THIS EXISTS
      Two numbers were quoted around this project as "measured": the browser
      costing ~12 FPS, and the page's CSS viewport being a fixed 1200x600. The
      FPS pair was never an A/B -- the "68 idle" half had no recorded provenance
      and was not sampled the same way as the "with browser" half. The viewport
      was one real sample, but "fixed regardless of resolution" was an inference
      drawn from that single point.

      A third claim from the same batch, that typed text cannot reach the DOM,
      turned out to be false and to have come from a probe that measured
      nothing. So these get re-measured rather than repeated.

    WHAT IT DOES
      Samples diag_fps three times with an identical method -- before the browser
      is open, while it is open and idle, and after it is closed again. The
      third pass matters: if FPS does not return to baseline, the cost is not
      the browser. Then asks the page for its own viewport numbers and prints
      the control's true pixel size beside them, so "fixed 1200x600" can be
      checked rather than assumed.

      Stand still somewhere quiet and do not move the mouse while it runs.

    Usage (debug console):  [] spawn webui_fnc_bench;
    Takes ~25s. Results go to the RPT, tagged [WEBUI-BENCH].
*/

if (!canSuspend) exitWith { diag_log "[WEBUI-BENCH] needs a scheduled context -- use spawn"; };

private _sampleFps = {
    params ["_label", ["_secs", 6]];
    private _n = 0; private _sum = 0; private _min = 1e9; private _max = 0;
    private _end = diag_tickTime + _secs;
    while { diag_tickTime < _end } do {
        private _f = diag_fps;
        _sum = _sum + _f; _n = _n + 1;
        if (_f < _min) then { _min = _f };
        if (_f > _max) then { _max = _f };
        uiSleep 0.2;
    };
    private _mean = if (_n > 0) then { _sum / _n } else { 0 };
    diag_log format ["[WEBUI-BENCH] %1: mean %2 fps  min %3  max %4  (%5 samples)",
        _label, _mean toFixed 1, _min toFixed 1, _max toFixed 1, _n];
    _mean
};

diag_log "[WEBUI-BENCH] ---- start ---- stand still, do not move the mouse";

// A: nothing open. Close whatever is up and let it settle.
if (dialog) then { closeDialog 0; uiSleep 1; };
// VERIFY THE BASELINE IS ACTUALLY BASELINE. A' aborts when a control is still
// alive; A never checked at all, so the "no browser" sample could be taken with
// an RscTitles page already up -- and then B minus A is the cost of nothing.
if (!isNull (uiNamespace getVariable ["WEBUI_ctrl", controlNull])) exitWith {
    diag_log "[WEBUI-BENCH] ABORT: a browser control is already live, so the 'no browser' baseline would not be one. Close every web page (an RscTitles overlay does not close with Esc) and rerun.";
    systemChat "bench ABORTED -- a page is already open (see RPT)";
};
private _before = ["A baseline, no browser"] call _sampleFps;

// B: browser open and idle. The library does not know the host's dialog names,
// so arm this first and open your page when told.
// Use the shared helper rather than a private copy of it. This inlined the
// same "wait for non-null" defect webui_fnc_awaitPage had: WEBUI_ctrl is never
// cleared, so a leftover RscTitles overlay (which Esc does not close, FINDINGS
// 8) was adopted instantly and the whole A/B/A was measured against a control
// the operator never opened.
diag_log "[WEBUI-BENCH] open a page now (waiting up to 45s)";
private _ctrl = [45, 3] call webui_fnc_awaitPage;
if (isNull _ctrl) exitWith { diag_log "[WEBUI-BENCH] no page was opened"; };
private _disp = ctrlParent _ctrl;
// The automatic clamp check fires ~2s after the first ready page and drives a
// forced 60Hz style mutation for 3s. Sampling "browser open, IDLE" across that
// measures the clamp check, not idle cost. Wait for it to have filed a verdict
// (or to have been opted out of) before sampling.
private _clampWait = diag_tickTime + 12;
waitUntil {
    uiSleep 0.25;
    isNull _ctrl
      || { !isNil { missionNamespace getVariable "webui_clampVerdict" } }
      || { missionNamespace getVariable ["webui_clampCheckDisabled", false] }
      || { diag_tickTime > _clampWait }
};
if (isNull _ctrl) exitWith { diag_log "[WEBUI-BENCH] control went away before the B sample"; };
if (_ctrl getVariable ["webui_drawBusy", false]) then {
    diag_log "[WEBUI-BENCH] WARNING: a draw sample is still running on this control; the B figure below may include its forced mutation.";
};
private _during = ["B browser open, idle"] call _sampleFps;

// what the control actually is, in pixels, vs what the page thinks it has
private _res = getResolution;                  // [w, h, viewW, viewH, aspect, uiScale]
private _pos = ctrlPosition _ctrl;             // [x, y, w, h] in UI coords
// UI coords are NOT fractions of the screen: on a 21:9 display safeZoneW is
// ~1.55, so multiplying straight by screen width overstates the size badly
// (it once printed a 3880px control on a 3440px screen). Divide by safeZone.
diag_log format ["[WEBUI-BENCH] screen %1x%2  uiScale %3  safeZone %4x%5  control %6 x %7 px  (UI w=%8 h=%9)",
    _res select 0, _res select 1, _res select 5,
    safeZoneWAbs toFixed 4, safeZoneH toFixed 4,
    // safeZoneWAbs, not safeZoneW: getResolution's width spans ALL monitors,
    // while safeZoneW spans only the centre one, so pairing them reported a
    // control 3x too wide on a triple-head setup. The BIKI notes safezoneWAbs
    // "is same as safezoneW" on a single monitor, so this is a no-op there.
    round (((_pos select 2) / safeZoneWAbs) * (_res select 0)),
    round (((_pos select 3) / safeZoneH) * (_res select 1)),
    (_pos select 2) toFixed 4, (_pos select 3) toFixed 4];

// `metrics` is registered only by ui/demo.html, so on any other page this call
// times out and returns nil -- and formatting a nil in a SCHEDULED context
// raises "Undefined variable in expression" rather than printing "any" (BIKI,
// nil). That abort killed the rest of the run: closeDialog, the A' recovery
// sample and the whole A/B/A verdict never happened, and nothing said the run
// had been truncated. The operator got two orphan "mean N fps" lines.
private _m = [_ctrl, "metrics", [], 8] call webui_fnc_call;
if (isNil "_m") then { _m = "no 'metrics' handler on this page (only ui/demo.html registers one)"; };
diag_log format ["[WEBUI-BENCH] page metrics: %1", _m];

// A': closed again -- if this does not come back to baseline, the browser was
// not what cost the frames
// closeDialog only closes a DIALOG. A browser control commonly lives in an
// RscTitles overlay -- this repo's own awaitPage and bootProbe say so, and the
// CT_WEBBROWSER wiki's HUD example does exactly that -- and Esc does not close
// those either. So this could close nothing, the A' sample would measure the
// browser still painting, and the A/B/A verdict would be computed and printed
// from three samples of the same state. Verify the control is actually gone,
// and refuse to publish a verdict if it is not.
closeDialog 0;
private _closeBy = diag_tickTime + 3;
waitUntil { uiSleep 0.25; isNull _ctrl || { diag_tickTime > _closeBy } };
if (!isNull _ctrl) exitWith {
    diag_log "[WEBUI-BENCH] ABORT: the browser control is still alive after closeDialog -- it is probably in an RscTitles overlay, which closeDialog cannot close. Close the page by hand and rerun; no A/B/A verdict without a real A' sample.";
    systemChat "bench ABORTED -- could not close the page (see RPT)";
};
uiSleep 2;
private _after = ["A' closed again"] call _sampleFps;

diag_log format ["[WEBUI-BENCH] ---- result ---- baseline %1 / open %2 / recovered %3  => browser costs %4 fps (%5%6)",
    _before toFixed 1, _during toFixed 1, _after toFixed 1,
    (_before - _during) toFixed 1,
    (if (_before > 0) then { round (100 * (_before - _during) / _before) } else { 0 }), "%"];
if (_after < _before * 0.9) then {
    diag_log "[WEBUI-BENCH] WARNING: FPS did not recover after closing -- something other than the browser moved, treat the delta as unreliable";
};
