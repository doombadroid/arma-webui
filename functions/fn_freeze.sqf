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
    // ResumeBrowser renavigates the frame, so window.WEBUI is destroyed and
    // rebuilt from scratch. Without clearing this, webui_fnc_exec would keep
    // believing the bridge was live and send straight into a document that does
    // not have one yet -- every statement silently short-circuiting on its own
    // `window.WEBUI &&` guard.
    _c setVariable ["webui_bridge", false];
    _c setVariable ["webui_initAt", diag_tickTime];
    _c setVariable ["webui_readyAt", nil];
    _c setVariable ["webui_readySignal", nil];
    _c setVariable ["webui_bridgeAt", nil];
};

if (_resume) then {
    [_ctrl] call _resetReadyClock;                 // PageLoaded will set it again
    _ctrl ctrlWebBrowserAction ["ResumeBrowser"];
    diag_log "[WEBUI] browser resumed";

    // RE-APPLY ANY SERVE OVERRIDE. ResumeBrowser renavigates the frame, which
    // loads the control's url= -- the PBO page. A webui_fnc_serve override lives
    // only in the document that was just destroyed, so without this the screen
    // silently reverts to the baseline markup and stays there, with nothing in
    // the RPT to say an override had ever been applied.
    //
    // The stamp is cleared first or fn_serve's redundancy guard would see the
    // pre-freeze markup on the control and skip. The re-apply goes through
    // webui_fnc_exec, so it waits for the bridge like any other statement.
    private _servedId = _ctrl getVariable ["webui_servePageId", ""];
    if (_servedId isNotEqualTo "") then {
        _ctrl setVariable ["webui_serveApplied", ""];
        diag_log format ["[WEBUI] re-applying serve override '%1' after resume", _servedId];
        [_ctrl, _servedId] call webui_fnc_serve;
    };
} else {
    _ctrl ctrlWebBrowserAction ["StopBrowser"];
    [_ctrl] call _resetReadyClock;
    diag_log "[WEBUI] browser frozen (last frame kept, resources released)";
};
true
