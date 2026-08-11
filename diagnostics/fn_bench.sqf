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
private _before = ["A baseline, no browser"] call _sampleFps;

// B: browser open and idle. The library does not know the host's dialog names,
// so arm this first and open your page when told.
diag_log "[WEBUI-BENCH] open a page now (waiting up to 45s)";
private _deadline = diag_tickTime + 45;
private _ctrl = controlNull;
waitUntil {
    uiSleep 0.5;
    _ctrl = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
    !isNull _ctrl || { diag_tickTime > _deadline }
};
if (isNull _ctrl) exitWith { diag_log "[WEBUI-BENCH] no page was opened"; };
uiSleep 3;
private _disp = ctrlParent _ctrl;
private _during = ["B browser open, idle"] call _sampleFps;

// what the control actually is, in pixels, vs what the page thinks it has
private _res = getResolution;                  // [w, h, viewW, viewH, aspect, uiScale]
private _pos = ctrlPosition _ctrl;             // [x, y, w, h] in UI coords
// UI coords are NOT fractions of the screen: on a 21:9 display safeZoneW is
// ~1.55, so multiplying straight by screen width overstates the size badly
// (it once printed a 3880px control on a 3440px screen). Divide by safeZone.
diag_log format ["[WEBUI-BENCH] screen %1x%2  uiScale %3  safeZone %4x%5  control %6 x %7 px  (UI w=%8 h=%9)",
    _res select 0, _res select 1, _res select 5,
    safeZoneW toFixed 4, safeZoneH toFixed 4,
    round (((_pos select 2) / safeZoneW) * (_res select 0)),
    round (((_pos select 3) / safeZoneH) * (_res select 1)),
    (_pos select 2) toFixed 4, (_pos select 3) toFixed 4];

private _m = [_ctrl, "metrics", [], 8] call webui_fnc_call;
diag_log format ["[WEBUI-BENCH] page metrics: %1", _m];

// A': closed again -- if this does not come back to baseline, the browser was
// not what cost the frames
closeDialog 0;
uiSleep 2;
private _after = ["A' closed again"] call _sampleFps;

diag_log format ["[WEBUI-BENCH] ---- result ---- baseline %1 / open %2 / recovered %3  => browser costs %4 fps (%5%6)",
    _before toFixed 1, _during toFixed 1, _after toFixed 1,
    (_before - _during) toFixed 1,
    (if (_before > 0) then { round (100 * (_before - _during) / _before) } else { 0 }), "%"];
if (_after < _before * 0.9) then {
    diag_log "[WEBUI-BENCH] WARNING: FPS did not recover after closing -- something other than the browser moved, treat the delta as unreliable";
};
