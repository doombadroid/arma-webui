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

if (_resume) then {
    _ctrl setVariable ["webui_ready", false];      // PageLoaded will set it again
    _ctrl ctrlWebBrowserAction ["ResumeBrowser"];
    diag_log "[WEBUI] browser resumed";
} else {
    _ctrl ctrlWebBrowserAction ["StopBrowser"];
    _ctrl setVariable ["webui_ready", false];
    diag_log "[WEBUI] browser frozen (last frame kept, resources released)";
};
true
