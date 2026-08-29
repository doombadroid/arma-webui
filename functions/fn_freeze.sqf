// SPDX-License-Identifier: MIT
/*
    fn_webFreeze.sqf -- stop or resume a page's browser.

    StopBrowser keeps the LAST DRAWN FRAME on screen and shuts the browser down,
    freeing its CPU and memory.

    NOT for frame rate. Measured A/B/A, the browser has no measurable frame
    cost, so there are no frames here to reclaim. Freeze to release memory on a
    screen that has finished rendering, or to stop a page animating in the
    background. See docs/FINDINGS.md.

    Freeze only once the page has actually drawn what you want frozen. Resuming
    reloads the URL, which takes a few frames and shows one or two black ones,
    and it fires PageLoaded again -- so WEBUI is rebuilt and every channel has to be
    re-pushed. webui_fnc_init's PageLoaded handler re-injects webui.js for
    exactly this reason.

    Usage:
        [_ctrl, false] call webui_fnc_freeze;   // freeze
        [_ctrl, true]  call webui_fnc_freeze;   // resume
*/

params [["_ctrl", controlNull, [controlNull]], ["_resume", false, [false]]];
if (isNull _ctrl) exitWith { false };

// Readiness is about to be re-run, so the readiness CLOCK has to restart with
// it. webui_readyAt is re-stamped by the next mark but webui_initAt is written
// only by fn_init, so without this the two belong to different epochs and
// webui_fnc_bootProbe reports "init -> ready" as the whole time the page spent
// frozen -- a healthy page resumed after two minutes reads "SLOW -- 120.34s to
// first data", indistinguishable from a real failure on the one screen a
// non-developer is asked to screenshot.
private _resetReadyClock = {
    params ["_c"];
    _c setVariable ["webui_ready", false];
    _c setVariable ["webui_initAt", diag_tickTime];
    _c setVariable ["webui_readyAt", nil];
    _c setVariable ["webui_readySignal", nil];
};

if (_resume) then {
    [_ctrl] call _resetReadyClock;                 // PageLoaded will set it again
    _ctrl ctrlWebBrowserAction ["ResumeBrowser"];
    diag_log "[WEBUI] browser resumed";
} else {
    _ctrl ctrlWebBrowserAction ["StopBrowser"];
    [_ctrl] call _resetReadyClock;
    diag_log "[WEBUI] browser frozen (last frame kept, resources released)";
};
true
