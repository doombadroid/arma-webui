// SPDX-License-Identifier: MIT
/*
    fn_selfTest.sqf -- is this install safe to hand to someone else?

    Runs every check that can be made without a human, against a LIVE page, and
    prints one verdict. Green means the bridge works end to end on this client
    and the specific defects fixed in the 2026-08-28 run have not come back.

    NON-DESTRUCTIVE BY CONSTRUCTION. It never replaces page markup, never opens
    a dialog, never writes to profileNamespace, and restores every global it
    borrows. The serve check deliberately answers with an EMPTY page so the
    ticket machinery runs end to end while the document is left alone.

    WHAT IT CANNOT CHECK, and why -- these still need a person:

      * Frame delivery. webui_fnc_clampCheck already files that verdict
        separately (FINDINGS 1). This test reports what it found but does not
        fail on it, because a clamped client is a launch-path problem, not an
        install problem.
      * The volume slider fix. radioVolume only changes when a human moves the
        Radio slider. Open a page, run webui_fnc_volumeSlave, move ONLY that
        slider, and confirm the page's gain follows.
      * The prompt overlay's appearance. The busy guard and generation stamp are
        checked here; whether the box draws correctly is a look.
      * Anything about a page's own content.

    Usage:  [] spawn webui_fnc_selfTest;        // arm, then open any page
            [_ctrl] spawn webui_fnc_selfTest;   // a page already open

    Leaves missionNamespace "webui_selfTestVerdict" as "green" | "red", and
    "webui_selfTestFails" as an array of the checks that failed.
*/

params [["_ctrl", controlNull, [controlNull]]];
if (!canSuspend) exitWith { diag_log "[WEBUI-TEST] needs a scheduled context -- spawn it"; false };

private _results = [];
private _fails   = [];
private _check = {
    params ["_name", "_ok", ["_detail", ""]];
    _results pushBack [_name, _ok, _detail];
    if (!_ok) then { _fails pushBack _name; };
    diag_log format ["[WEBUI-TEST] %1 %2%3",
        ["FAIL", "PASS"] select _ok, _name,
        if (_detail isEqualTo "") then { "" } else { format ["  --  %1", _detail] }];
};

// ------------------------------------------------------------------ page --
// Same change-detection as webui_fnc_bootProbe: WEBUI_ctrl is never cleared, so
// "non-null" would adopt a leftover overlay and test the wrong control.
private _before = controlNull;
if (isNull _ctrl) then {
    _before = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
    diag_log "[WEBUI-TEST] armed -- open any page now (waiting up to 60s)";
    private _armDeadline = diag_tickTime + 60;
    waitUntil {
        uiSleep 0.25;
        _ctrl = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
        (!isNull _ctrl && { _ctrl isNotEqualTo _before }) || { diag_tickTime > _armDeadline }
    };
};
if (isNull _ctrl || { _ctrl isEqualTo _before }) exitWith {
    diag_log "[WEBUI-TEST] no page opened -- nothing tested";
    hint parseText "<t size='1.1' color='#c9e21a'>WEBUI SELF TEST</t><br/><t color='#dfe8f0'>No page opened. Nothing tested.</t>";
    false
};

// let the normal boot happen on its own terms before measuring it
private _deadline = diag_tickTime + 6;
waitUntil {
    uiSleep 0.1;
    isNull _ctrl || { _ctrl getVariable ["webui_ready", false] } || { diag_tickTime > _deadline }
};
if (isNull _ctrl) exitWith { diag_log "[WEBUI-TEST] control went away"; false };

// ------------------------------------------------------------- readiness --
private _signal = _ctrl getVariable ["webui_readySignal", "none"];
private _initAt = _ctrl getVariable ["webui_initAt", -1];
private _readyA = _ctrl getVariable ["webui_readyAt", -1];
private _delta  = if (_initAt >= 0 && _readyA >= 0) then { _readyA - _initAt } else { -1 };

["bridge is up", _ctrl getVariable ["webui_ready", false], format ["signal=%1", _signal]] call _check;

// 'timer' means nothing reached the page for three seconds. That is the exact
// symptom this whole run existed to remove, so it is a hard fail.
["readiness did not fall to the 3s backstop", _signal isNotEqualTo "timer",
    format ["signal=%1", _signal]] call _check;

["readiness inside 1s", _delta >= 0 && { _delta < 1 },
    if (_delta >= 0) then { format ["%1s", _delta toFixed 3] } else { "no timestamp" }] call _check;

// ---------------------------------------------------------- page answers --
// A registered handler the page can reach proves the JSDialog leg both ways.
// Deliberately NOT webui_fnc_call here: that invokes a handler registered in the
// PAGE with WEBUI.handle, and a generic page exposes none, so it would sit for
// its full 10s timeout and prove nothing. Drive the page with ExecJS instead and
// have it call back into a handler registered here.
uiNamespace setVariable ["WEBUI_selfTestEcho", nil];
[_ctrl, "__selfTestEcho", {
    uiNamespace setVariable ["WEBUI_selfTestEcho", true];
    createHashMapFromArray [["ok", true]]
}] call webui_fnc_on;
_ctrl ctrlWebBrowserAction ["ExecJS",
    "(function(){try{ if(window.WEBUI) WEBUI.call('__selfTestEcho',[]); }catch(e){}})();"];
private _echoBy = diag_tickTime + 5;
waitUntil { uiSleep 0.1; !isNil { uiNamespace getVariable "WEBUI_selfTestEcho" } || { diag_tickTime > _echoBy } };
["page -> SQF call arrives", !isNil { uiNamespace getVariable "WEBUI_selfTestEcho" },
    "page called a registered handler"] call _check;

// --------------------------------------------------------- SQF -> page ----
// Push a value and read it back out of the page, which proves the queue drained
// into a document that really has the bridge rather than one that merely renders.
private _token = str round (diag_tickTime * 1000);
[_ctrl, "__selfTestPush", _token] call webui_fnc_push;
uiNamespace setVariable ["WEBUI_selfTestPush", nil];
[_ctrl, "__selfTestPushBack", {
    params [["_v", "", [""]]];
    uiNamespace setVariable ["WEBUI_selfTestPush", _v];
    createHashMapFromArray [["ok", true]]
}] call webui_fnc_on;
uiSleep 0.3;
_ctrl ctrlWebBrowserAction ["ExecJS",
    "(function(){try{ if(window.WEBUI) WEBUI.call('__selfTestPushBack',[String(WEBUI.get('__selfTestPush'))]); }catch(e){}})();"];
private _pushBy = diag_tickTime + 5;
waitUntil { uiSleep 0.1; !isNil { uiNamespace getVariable "WEBUI_selfTestPush" } || { diag_tickTime > _pushBy } };
private _got = uiNamespace getVariable ["WEBUI_selfTestPush", ""];
["SQF -> page push lands", _got isEqualTo _token, format ["sent %1, page read %2", _token, _got]] call _check;

// ------------------------------------------------------------ boot path ---
uiNamespace setVariable ["WEBUI_selfTestBoot", nil];
[_ctrl, "__selfTestBoot", {
    params [["_p", "?", [""]]];
    uiNamespace setVariable ["WEBUI_selfTestBoot", _p];
    createHashMapFromArray [["ok", true]]
}] call webui_fnc_on;
_ctrl ctrlWebBrowserAction ["ExecJS",
    "(function(){try{ if(window.WEBUI) WEBUI.call('__selfTestBoot',[String(WEBUI.bootPath||'?')]); }catch(e){}})();"];
private _bootBy = diag_tickTime + 5;
waitUntil { uiSleep 0.1; !isNil { uiNamespace getVariable "WEBUI_selfTestBoot" } || { diag_tickTime > _bootBy } };
private _bootPath = uiNamespace getVariable ["WEBUI_selfTestBoot", "?"];
["boot path is reported", _bootPath in ["stub", "sqf", "unstamped"],
    format ["bootPath=%1", _bootPath]] call _check;
// Neither of these is a failure, and the difference between them matters:
// "sqf" is a real finding, "unstamped" is the tool admitting it cannot tell.
// Reporting the second as the first sends the reader to fix a stub that works.
if (_bootPath isEqualTo "sqf") then {
    diag_log "[WEBUI-TEST] NOTE this page has no working self-boot stub (INSTALL.md step 6). It works, but it is the slow and fragile path.";
};
if (_bootPath isEqualTo "unstamped") then {
    diag_log "[WEBUI-TEST] NOTE boot path unknown -- this page's stub predates the stamp. NOT a fault. Add window.__webuiBootPath = 'stub'; to the stub, or read the RPT: 'inject: loadFile' with no 'webui.js N bytes' after it means SQF delivered nothing and the stub must have.";
};

// ------------------------------------------------- serve async callback ---
// REGRESSION TEST FOR THE CLOSURE FIX. The callback used to reference this
// function's locals, which do not exist once the fetcher answers from another
// scope, so an ASYNCHRONOUS answer died on "Undefined variable" and silently
// dropped the override. Observable without touching the document: the receiver
// deletes its ticket from webui_servePending BEFORE it looks at the markup, so
// answering with an empty page runs the whole ticket path and changes nothing
// on screen. If the ticket is still pending afterwards, the callback died.
private _savedFetcher = missionNamespace getVariable ["webui_serveFetcher", nil];
private _savedEnabled = missionNamespace getVariable ["webui_serveEnabled", nil];
webui_serveEnabled = true;
webui_serveFetcher = {
    params ["_pageId", "_have", "_cb"];
    // ANSWER FROM ANOTHER SCOPE, ON PURPOSE. A synchronous answer would pass
    // even with the bug, because a called block inherits the caller's scope.
    [_cb] spawn { params ["_cb"]; uiSleep 0.5; [""] call _cb; };
};
private _pendBefore = count (uiNamespace getVariable ["webui_servePending", createHashMap]);
[_ctrl, "__selfTestServePage", 30] call webui_fnc_serve;
private _pend = uiNamespace getVariable ["webui_servePending", createHashMap];
private _ticketSeen = (count _pend) > _pendBefore;
uiSleep 2;                                        // well inside the 30s expiry
_pend = uiNamespace getVariable ["webui_servePending", createHashMap];
private _cleared = (count _pend) <= _pendBefore;
["serve callback survives an async fetcher", _ticketSeen && _cleared,
    if (!_ticketSeen) then { "serve never armed a ticket -- is a fetcher set?" }
    else { if (_cleared) then { "ticket consumed by the late answer" }
           else { "TICKET STILL PENDING -- the callback died (closure regression)" } }] call _check;
// restore, exactly as found
if (isNil "_savedFetcher") then { missionNamespace setVariable ["webui_serveFetcher", nil]; }
else { missionNamespace setVariable ["webui_serveFetcher", _savedFetcher]; };
if (isNil "_savedEnabled") then { missionNamespace setVariable ["webui_serveEnabled", nil]; }
else { missionNamespace setVariable ["webui_serveEnabled", _savedEnabled]; };

// ------------------------------------------------------------- prompt -----
// Guard only, no UI: a prompt that cannot have the overlay must refuse rather
// than retitle the box under the one already running and release both.
// ONLY MEANINGFUL IF THE OVERLAY IS ACTUALLY IN THIS DIALOG. fn_prompt returns
// nil early when idc 937413 is missing, so on a dialog that never included
// prompt_overlay.hpp this check would report PASS for entirely the wrong reason
// -- a green light earned by the feature being absent. Detect that and say so
// instead of counting it.
private _promptDisplay = ctrlParent _ctrl;
private _haveOverlay = false;
if (!isNull _promptDisplay) then {
    _haveOverlay = !isNull (_promptDisplay displayCtrl 937413);
};
if (!_haveOverlay) then {
    diag_log "[WEBUI-TEST] SKIP prompt guard -- this dialog does not include prompt_overlay.hpp (idc 937413 absent), so the check cannot distinguish a working guard from a missing overlay. Run this against a dialog that has it.";
} else {
    // getVariable-with-a-default, NOT `with uiNamespace do { NAME }`. The latter
    // RAISES on an undefined variable rather than yielding nil, and the first
    // version of this test did exactly that: it set WEBUI_promptBusy before
    // calling fn_prompt, which skipped fn_prompt's own initialisation and left
    // WEBUI_promptGen undefined, so both reads threw, both fell back to 0, and
    // "gen 0 -> 0" reported PASS while comparing two fallbacks. A check that
    // cannot fail is worse than no check -- it spends the reader's trust.
    private _genSaved = uiNamespace getVariable ["WEBUI_promptGen", 0];

    // SEED A SENTINEL so "unchanged" is a real assertion. Comparing the value to
    // itself proves nothing if both sides can quietly default to the same number.
    private _sentinel = 424242;
    uiNamespace setVariable ["WEBUI_promptGen", _sentinel];
    uiNamespace setVariable ["WEBUI_promptBusy", true];
    private _refused = ["selftest", "", 8] call webui_fnc_prompt;
    uiNamespace setVariable ["WEBUI_promptBusy", false];
    ["prompt refuses re-entry while busy", isNil "_refused",
        "second concurrent prompt returned nil instead of stealing the overlay"] call _check;

    private _genAfter = uiNamespace getVariable ["WEBUI_promptGen", -1];
    ["prompt generation untouched by a refusal", _genAfter isEqualTo _sentinel,
        format ["seeded %1, read back %2", _sentinel, _genAfter]] call _check;

    // fn_prompt must leave the generation DEFINED whatever happens, or
    // prompt_overlay.hpp's button handler throws mid-click.
    ["prompt generation is always initialised", !isNil { uiNamespace getVariable "WEBUI_promptGen" },
        "WEBUI_promptGen exists after a refused prompt"] call _check;

    uiNamespace setVariable ["WEBUI_promptGen", _genSaved];   // restore
};

// --------------------------------------------------------------- hygiene --
private _q = count (_ctrl getVariable ["webui_queue", []]);
["exec queue is not backed up", _q < 50, format ["%1 statement(s) held", _q]] call _check;

private _clamp = missionNamespace getVariable ["webui_clampVerdict", "unknown"];
private _clampFps = missionNamespace getVariable ["webui_clampFps", -1];

// ---------------------------------------------------------------- report --
private _green = (count _fails) isEqualTo 0;
missionNamespace setVariable ["webui_selfTestVerdict", ["red", "green"] select _green];
missionNamespace setVariable ["webui_selfTestFails", _fails];

private _lines = "";
{
    _x params ["_n", "_ok", "_d"];
    _lines = _lines + format ["<br/><t color='%1'>%2</t> %3",
        ["#e35b5b", "#38e1c4"] select _ok, ["FAIL", "PASS"] select _ok, _n];
} forEach _results;

private _clampNote = "";
if (_clamp isEqualTo "clamped") then {
    _clampNote = format ["<br/><br/><t color='#c9e21a'>NOTE frame delivery is CLAMPED (%1 fps).</t> Pages will look frozen on this client. Launch through Steam -- FINDINGS 1. Not an install fault.", _clampFps toFixed 1];
};

hint parseText format [
    "<t size='1.2' color='%1'>WEBUI SELF TEST: %2</t><br/><t color='#7f93a6'>%3 of %4 checks passed</t>%5%6",
    ["#e35b5b", "#38e1c4"] select _green,
    ["RED", "GREEN"] select _green,
    (count _results) - (count _fails), count _results,
    _lines, _clampNote
];

diag_log format ["[WEBUI-TEST] ================ VERDICT: %1  (%2/%3 passed) ================",
    ["RED", "GREEN"] select _green, (count _results) - (count _fails), count _results];
if (!_green) then { diag_log format ["[WEBUI-TEST] failed: %1", _fails]; };
diag_log format ["[WEBUI-TEST] clamp=%1 bootPath=%2 signal=%3 readyIn=%4s",
    _clamp, _bootPath, _signal, if (_delta >= 0) then { _delta toFixed 3 } else { "n/a" }];

_green
