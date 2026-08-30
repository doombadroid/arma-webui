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
      * The volume slider fix. The quantity that tracks the Radio slider is
        `getAudioOptionVolumes select 2` -- NOT radioVolume, which is the
        scripted fade coefficient and does not move when a human moves the
        slider at all. That confusion is what made this subsystem read the
        wrong values for its whole existence, and only a human moving the
        slider can confirm the right ones are being read. Open a page, run
        webui_fnc_volumeSlave, move ONLY that slider, and confirm the page's
        gain follows.
      * The prompt overlay's appearance. The busy guard and generation stamp are
        checked here; whether the box draws correctly is a look.
      * Anything about a page's own content.

    Usage:  [] spawn webui_fnc_selfTest;        // arm, then open any page
            [_ctrl] spawn webui_fnc_selfTest;   // a page already open

    ONE EXCEPTION to "never opens a dialog": the stale-latch check has to let
    fn_prompt reach its body, so the prompt overlay is shown for up to six
    seconds. It is announced with a systemChat, it is bounded, and the overlay,
    the busy latch and keyboard focus are all restored afterwards. Leave it
    alone while it runs; dismissing it does not fail the check.

    Leaves missionNamespace "webui_selfTestVerdict" as "green" | "red" |
    "aborted", and "webui_selfTestFails" as an array of the checks that failed.

    "aborted" means the run tested NOTHING -- it was not spawned, no page was
    opened within the arming window, or the control went away mid-run. It is
    neither a pass nor a fail, and "webui_selfTestFails" is empty for it, so a
    consumer must test for "green" explicitly rather than treating not-"red" as
    success. The value exists because these exits used to leave the PREVIOUS
    run's verdict standing.
*/

params [["_ctrl", controlNull, [controlNull]]];
if (!canSuspend) exitWith {
    // The only abort that used to leave the PREVIOUS run's verdict standing.
    missionNamespace setVariable ["webui_selfTestVerdict", "aborted"];
    missionNamespace setVariable ["webui_selfTestFails", []];
    diag_log "[WEBUI-TEST] needs a scheduled context -- spawn it";
    false
};

private _results = [];
private _fails   = [];
// State is 0 FAIL / 1 PASS / 2 SKIP. SKIP is a first-class result and MUST
// reach _results: skipped checks used to be logged and then omitted entirely,
// so a run that could not test the prompt printed "GREEN -- 8 of 8 checks
// passed", which is indistinguishable from a full pass in the screenshot
// docs/HANDOFF_TEST.md asks a third party to send back.
private _check = {
    params ["_name", "_ok", ["_detail", ""]];
    _results pushBack [_name, parseNumber _ok, _detail];
    if (!_ok) then { _fails pushBack _name; };
    diag_log format ["[WEBUI-TEST] %1 %2%3",
        ["FAIL", "PASS"] select _ok, _name,
        if (_detail isEqualTo "") then { "" } else { format ["  --  %1", _detail] }];
};
private _skip = {
    params ["_name", ["_detail", ""]];
    _results pushBack [_name, 2, _detail];
    diag_log format ["[WEBUI-TEST] SKIP %1%2", _name,
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
// Every abort clears the verdict. These exits used to return without touching
// missionNamespace, so an aborted run left the PREVIOUS run's "green" standing
// for anything that reads webui_selfTestVerdict -- a stale pass reported as a
// current one.
private _abort = {
    params ["_why"];
    missionNamespace setVariable ["webui_selfTestVerdict", "aborted"];
    missionNamespace setVariable ["webui_selfTestFails", []];
    diag_log format ["[WEBUI-TEST] %1", _why];
};
if (isNull _ctrl || { _ctrl isEqualTo _before }) exitWith {
    ["no page opened -- nothing tested"] call _abort;
    hint parseText "<t size='1.1' color='#c9e21a'>WEBUI SELF TEST</t><br/><t color='#dfe8f0'>No page opened. Nothing tested.</t>";
    false
};

// let the normal boot happen on its own terms before measuring it
private _deadline = diag_tickTime + 6;
waitUntil {
    uiSleep 0.1;
    // Wait for the BRIDGE, not merely the page. Exiting as soon as the document
    // loaded would judge "bridge is up" at ~0.2s, before the injector's 3s
    // retry window has had any chance to deliver it -- a false RED on a install
    // that was about to come up fine.
    isNull _ctrl || { _ctrl getVariable ["webui_bridge", false] } || { diag_tickTime > _deadline }
};
if (isNull _ctrl) exitWith {
    ["control went away"] call _abort;
    hint parseText "<t size='1.1' color='#c9e21a'>WEBUI SELF TEST</t><br/><t color='#dfe8f0'>Control went away mid-run. Nothing tested.</t>";
    false
};

// ------------------------------------------------------------- readiness --
private _signal = _ctrl getVariable ["webui_readySignal", "none"];
private _initAt = _ctrl getVariable ["webui_initAt", -1];
private _readyA = _ctrl getVariable ["webui_readyAt", -1];
// The delta that matters is init -> BRIDGE, not init -> page-load. readyAt is
// stamped when the document loaded, which is earlier and does not imply the
// bridge exists, so measuring from it reports OK for exactly the boot delay
// this check exists to catch.
private _bridgeA = _ctrl getVariable ["webui_bridgeAt", -1];
private _delta  = if (_initAt >= 0 && _readyA >= 0) then { _readyA - _initAt } else { -1 };

// webui_BRIDGE, not webui_ready: the latter only says the page loaded, so this
// check used to go green on a page whose document was up and whose bridge had
// never appeared -- exactly the "renders but never populates" install.
["bridge is up", _ctrl getVariable ["webui_bridge", false],
    format ["signal=%1 pageLoaded=%2", _signal, _ctrl getVariable ["webui_ready", false]]] call _check;

// 'timer' means nothing reached the page for three seconds. That is the exact
// symptom this whole run existed to remove, so it is a hard fail.
["readiness did not fall to the 3s backstop", _signal isNotEqualTo "timer",
    format ["signal=%1", _signal]] call _check;

private _bridgeDelta = if (_initAt >= 0 && _bridgeA >= 0) then { _bridgeA - _initAt } else { -1 };
["bridge up inside 1s", _bridgeDelta >= 0 && { _bridgeDelta < 1 },
    if (_bridgeDelta >= 0) then {
        format ["%1s to bridge (page loaded at %2s)", _bridgeDelta toFixed 3,
            if (_delta >= 0) then { _delta toFixed 3 } else { "n/a" }]
    } else { "no bridge timestamp" }] call _check;

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
// The detail must describe what was OBSERVED, not restate the pass condition:
// _check prints it on both outcomes, so a constant success sentence made a red
// row read "FAIL page -> SQF call arrives -- page called a registered handler",
// asserting the very thing the verdict reports absent.
private _echoArrived = !isNil { uiNamespace getVariable "WEBUI_selfTestEcho" };
["page -> SQF call arrives", _echoArrived,
    if (_echoArrived) then { "page called a registered handler" }
    else { "no call arrived within the deadline -- the page has no A3API binding, or the bridge is not in this document" }] call _check;

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
// Save the control's serve stamps: fn_serve stamps webui_servePageId and
// webui_serveApplied, and fn_freeze reads the first on resume to re-apply an
// override. Without this the test repoints a live page at its own fake id.
private _savedServeId = _ctrl getVariable ["webui_servePageId", ""];
private _savedServeApplied = _ctrl getVariable ["webui_serveApplied", ""];

// ASSERT ON OUR OWN TICKET, not the map's SIZE: counting entries breaks in both
// directions if any other serve is in flight. webui_serveSeq names ours.
[_ctrl, "__selfTestServePage", 30] call webui_fnc_serve;
private _ticket = uiNamespace getVariable ["webui_serveSeq", 0];
private _pend = uiNamespace getVariable ["webui_servePending", createHashMap];
private _ticketSeen = _ticket in _pend;
uiSleep 2;                                        // well inside the 30s expiry
_pend = uiNamespace getVariable ["webui_servePending", createHashMap];
private _cleared = !(_ticket in _pend);
["serve callback survives an async fetcher", _ticketSeen && _cleared,
    if (!_ticketSeen) then { "serve never armed a ticket -- is a fetcher set?" }
    else { if (_cleared) then { "ticket consumed by the late answer" }
           else { "TICKET STILL PENDING -- the callback died (closure regression)" } }] call _check;
// restore, exactly as found
if (isNil "_savedFetcher") then { missionNamespace setVariable ["webui_serveFetcher", nil]; }
else { missionNamespace setVariable ["webui_serveFetcher", _savedFetcher]; };
if (isNil "_savedEnabled") then { missionNamespace setVariable ["webui_serveEnabled", nil]; }
else { missionNamespace setVariable ["webui_serveEnabled", _savedEnabled]; };

// restore the control's serve stamps, including back to unset
if (_savedServeId isEqualTo "") then { _ctrl setVariable ["webui_servePageId", nil]; }
else { _ctrl setVariable ["webui_servePageId", _savedServeId]; };
if (_savedServeApplied isEqualTo "") then { _ctrl setVariable ["webui_serveApplied", nil]; }
else { _ctrl setVariable ["webui_serveApplied", _savedServeApplied]; };

// ------------------------------------------------------------- prompt -----
// Guard only, no UI: a prompt that cannot have the overlay must refuse rather
// than retitle the box under the one already running and release both.
// ONLY MEANINGFUL IF THE OVERLAY IS ACTUALLY IN THIS DIALOG. fn_prompt returns
// nil early when idc 937413 is missing, so on a dialog that never included
// prompt_overlay.hpp this check would report PASS for entirely the wrong reason
// -- a green light earned by the feature being absent. Detect that and say so
// instead of counting it.
// RESOLVE THE OVERLAY THROUGH THE SAME CONTROL fn_prompt WILL USE. This used
// to read ctrlParent _ctrl, but fn_prompt resolves its display from
// uiNamespace WEBUI_ctrl -- the LAST control initialised. The two diverge
// whenever more than one browser control is live (FINDINGS 8 runs four), and
// then _ctrl's dialog having the overlay made every prompt check run
// while fn_prompt looked at a display without it, returned nil at its
// "overlay controls missing" exit, and every check passed for that reason --
// the exact absent-feature green light the comment above claims to prevent.
private _promptCtrl = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
private _promptDisplay = if (isNull _promptCtrl) then { displayNull } else { ctrlParent _promptCtrl };
private _haveOverlay = false;
if (!isNull _promptDisplay) then {
    _haveOverlay = !isNull (_promptDisplay displayCtrl 937413);
};
if (_promptCtrl isNotEqualTo _ctrl) then {
    diag_log format ["[WEBUI-TEST] note: fn_prompt will use WEBUI_ctrl, which is NOT the control under test (%1 vs %2)", _promptCtrl, _ctrl];
};
if (!_haveOverlay) then {
    // EVERY prompt check skips together; the list below is the single source of
    // truth for which those are. Emitting fewer skips than checks leaves the
    // difference out of _results, so this path counts fewer rows than the
    // overlay path -- the vanishing-check defect SKIP exists to prevent, which
    // has now happened twice. No counts here on purpose: naming the number is
    // what let it rot. The invariant is that both skip lists are identical and
    // cover every name with a `call _check` in the overlay branch.
    {
        [_x, "dialog has no prompt_overlay.hpp (idc 937413 absent)"] call _skip;
    } forEach [
        "prompt refuses re-entry while busy",
        "refused prompt leaves the running prompt's field alone",
        "prompt generation untouched by a refusal",
        "prompt generation is always initialised",
        "stale busy latch is cleared, not obeyed"
    ];
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
    private _ids = [937410, 937411, 937412, 937413, 937414, 937415];

    // REFUSE TO TEST THE GUARD BY BREAKING IT. These checks seed the overlay's
    // field and drive WEBUI_promptBusy directly. With a real prompt on screen
    // that overwrites what the player typed (OK reads idc 937413 straight out),
    // and dropping the flag lets a second prompt bump the generation the live
    // one waits on -- whose wait has no timeout. Reachable on the documented
    // workflow, so detect it and skip.
    private _promptLive = uiNamespace getVariable ["WEBUI_promptBusy", false];
    if (_promptLive && { isNull (uiNamespace getVariable ["WEBUI_promptOwner", displayNull]) }) then {
        diag_log "[WEBUI-TEST] busy latch is stale (owning display gone) -- treating as not live";
        _promptLive = false;
    };
    if (_promptLive) then {
        {
            [_x, "a prompt is live on screen -- testing the guard would corrupt it"] call _skip;
        } forEach [
            "prompt refuses re-entry while busy",
            "refused prompt leaves the running prompt's field alone",
            "prompt generation untouched by a refusal",
            "prompt generation is always initialised",
            "stale busy latch is cleared, not obeyed"
        ];
        diag_log "[WEBUI-TEST] SKIP prompt checks -- a prompt is open. Close it and rerun.";
    } else {

    // BOUNDED INVOCATION. fn_prompt's own wait has no timeout, so calling it
    // directly meant that removing the busy guard made this test HANG with an
    // overlay on screen -- the regression it exists to catch could never
    // produce a red result. Run it in its own thread, give up after a deadline,
    // and report the block as a FAILURE.
    private _runPrompt = {
        params ["_title", "_deadline"];
        uiNamespace setVariable ["WEBUI_selfTestPromptDone", false];
        uiNamespace setVariable ["WEBUI_selfTestPromptRet", "nil"];
        private _h = [_title] spawn {
            params ["_t"];
            // Non-empty prefill on purpose: a refusal that seeds before it
            // refuses would overwrite the sentinel with this, which is what the
            // "leaves the running prompt's field alone" check detects.
            private _r = [_t, "CLOBBER", 8] call webui_fnc_prompt;
            if (!isNil "_r") then { uiNamespace setVariable ["WEBUI_selfTestPromptRet", _r]; };
            uiNamespace setVariable ["WEBUI_selfTestPromptDone", true];
        };
        private _limit = diag_tickTime + _deadline;
        waitUntil {
            uiSleep 0.1;
            (uiNamespace getVariable ["WEBUI_selfTestPromptDone", false]) || { diag_tickTime > _limit }
        };
        if !(uiNamespace getVariable ["WEBUI_selfTestPromptDone", false]) then {
            terminate _h;
            { (_promptDisplay displayCtrl _x) ctrlShow false; } forEach _ids;
            // terminate stops the script at the next scheduler visit, so
            // fn_prompt's tail never runs: flag, owner and focus are all ours to
            // put back. Leaving the owner set while clearing the flag would hand
            // the next reader a latch whose two halves disagree.
            uiNamespace setVariable ["WEBUI_promptBusy", false];
            uiNamespace setVariable ["WEBUI_promptOwner", displayNull];
            if (!isNull _promptCtrl) then { ctrlSetFocus _promptCtrl; };
            "BLOCKED"
        } else {
            uiNamespace getVariable ["WEBUI_selfTestPromptRet", "nil"]
        };
    };

    // SEED A SENTINEL so "unchanged" is a real assertion. Comparing the value to
    // itself proves nothing if both sides can quietly default to the same number.
    private _sentinel = 424242;
    // SEED THE FIELD FIRST. Comparing the box to itself when both readings are
    // "" passes on a healthy build AND on the regressed one -- the check could
    // not fail. Put a sentinel in, then refuse a prompt carrying a DIFFERENT
    // prefill, so a regression that seeds before refusing visibly overwrites it.
    (_promptDisplay displayCtrl 937413) ctrlSetText "SENTINEL-BEFORE";
    private _fieldBefore = ctrlText (_promptDisplay displayCtrl 937413);
    uiNamespace setVariable ["WEBUI_promptGen", _sentinel];
    // OWNER TOO. fn_prompt now treats "busy with a null owner" as a corpse from a
    // prompt killed by a mission end, and clears it before the busy guard reads
    // it. A half-faked latch therefore no longer stands in for a live prompt: it
    // gets cleared, fn_prompt runs for real on the operator's page, overwrites
    // the sentinel, and three of these four checks fail RED on a healthy build
    // while a live overlay opens on screen. Model a whole prompt, not half of one.
    uiNamespace setVariable ["WEBUI_promptOwner", _promptDisplay];
    uiNamespace setVariable ["WEBUI_promptBusy", true];
    private _r1 = ["selftest", 6] call _runPrompt;   // _runPrompt prefills "CLOBBER"
    uiNamespace setVariable ["WEBUI_promptBusy", false];

    ["prompt refuses re-entry while busy", _r1 isEqualTo "nil",
        if (_r1 isEqualTo "BLOCKED") then {
            "fn_prompt did NOT refuse -- it blocked on its own wait, so the busy guard is gone"
        } else { format ["returned '%1' instead of nil", _r1] }] call _check;

    // The refusal must also leave the RUNNING prompt's overlay alone. Asserting
    // only the nil return missed the actual corruption: fn_prompt used to
    // retitle the box and overwrite the field before reaching its busy guard,
    // so the prompt already on screen returned the refused caller's prefill.
    private _fieldAfter = ctrlText (_promptDisplay displayCtrl 937413);
    ["refused prompt leaves the running prompt's field alone", _fieldAfter isEqualTo _fieldBefore,
        format ["field was '%1', now '%2'", _fieldBefore, _fieldAfter]] call _check;

    private _genAfter = uiNamespace getVariable ["WEBUI_promptGen", -1];
    ["prompt generation untouched by a refusal", _genAfter isEqualTo _sentinel,
        format ["seeded %1, read back %2", _sentinel, _genAfter]] call _check;

    // SEPARATE INVOCATION, generation CLEARED. Asserting "defined" straight
    // after seeding the sentinel above read back this test's own seed and could
    // never fail. Clearing it first makes fn_prompt's initialisation the only
    // thing that can satisfy the assertion.
    uiNamespace setVariable ["WEBUI_promptGen", nil];
    // OWNER TOO. fn_prompt now treats "busy with a null owner" as a corpse from a
    // prompt killed by a mission end, and clears it before the busy guard reads
    // it. A half-faked latch therefore no longer stands in for a live prompt: it
    // gets cleared, fn_prompt runs for real on the operator's page, overwrites
    // the sentinel, and three of these four checks fail RED on a healthy build
    // while a live overlay opens on screen. Model a whole prompt, not half of one.
    uiNamespace setVariable ["WEBUI_promptOwner", _promptDisplay];
    uiNamespace setVariable ["WEBUI_promptBusy", true];
    ["selftest-init", 6] call _runPrompt;
    uiNamespace setVariable ["WEBUI_promptBusy", false];
    private _genDefined = !isNil { uiNamespace getVariable "WEBUI_promptGen" };
    ["prompt generation is always initialised", _genDefined,
        if (_genDefined) then {
            format ["WEBUI_promptGen is %1 after a refused prompt that started with it cleared",
                uiNamespace getVariable ["WEBUI_promptGen", "?"]]
        } else {
            "WEBUI_promptGen is UNDEFINED after a refused prompt -- prompt_overlay.hpp's button handler will throw mid-click"
        }] call _check;

    // ---- the staleness path itself. A latch left by a prompt whose script was
    // killed has busy=true and a null owner; fn_prompt must treat that as a
    // corpse and proceed, not refuse. Safe here: this branch runs only when no
    // prompt is live, and _runPrompt's BLOCKED path restores overlay, flag and
    // focus.
    // ASSERT ON THE GENERATION, NOT THE RETURN VALUE. fn_prompt returns nil for
    // three reasons -- refused, cancelled, dialog closed -- so testing for nil
    // made a human dismissing the box look like the regression. A refusal leaves
    // the generation untouched; every path past the guard bumps it once.
    private _genBefore = uiNamespace getVariable ["WEBUI_promptGen", 0];
    uiNamespace setVariable ["WEBUI_promptOwner", displayNull];
    uiNamespace setVariable ["WEBUI_promptBusy", true];
    private _r3 = ["selftest-stale", 6] call _runPrompt;
    private _genAfterStale = uiNamespace getVariable ["WEBUI_promptGen", 0];
    uiNamespace setVariable ["WEBUI_promptBusy", false];
    uiNamespace setVariable ["WEBUI_promptOwner", displayNull];
    ["stale busy latch is cleared, not obeyed", _genAfterStale > _genBefore,
        if (_genAfterStale > _genBefore) then {
            format ["proceeded past the stale latch as it should (wait ended: %1)", _r3]
        } else {
            "fn_prompt REFUSED on a latch with no live owner -- a prompt killed by a mission end would disable prompts for the whole game session"
        }] call _check;

    uiNamespace setVariable ["WEBUI_promptGen", _genSaved];   // restore
    // The busy flag is borrowed state too: it was false on entry (we only get
    // here when _promptLive was false), so put it back that way explicitly
    // rather than leaving whatever the last check happened to write.
    uiNamespace setVariable ["WEBUI_promptBusy", false];
    uiNamespace setVariable ["WEBUI_promptOwner", displayNull];
    };
};

// --------------------------------------------------------------- hygiene --
private _q = count (_ctrl getVariable ["webui_queue", []]);
["exec queue is not backed up", _q < 50, format ["%1 statement(s) held", _q]] call _check;

// The docstring promises this function "restores every global it borrows". It
// did not: four handlers and three uiNamespace variables stayed on the
// operator's live page after the run.
{ [_ctrl, _x] call webui_fnc_off; } forEach
    ["__selfTestEcho", "__selfTestPush", "__selfTestPushBack", "__selfTestBoot"];
{ uiNamespace setVariable [_x, nil]; } forEach
    ["WEBUI_selfTestPromptDone", "WEBUI_selfTestPromptRet",
     "WEBUI_selfTestEcho", "WEBUI_selfTestPush", "WEBUI_selfTestBoot"];

private _clamp = missionNamespace getVariable ["webui_clampVerdict", "unknown"];
private _clampFps = missionNamespace getVariable ["webui_clampFps", -1];

// ---------------------------------------------------------------- report --
private _green = (count _fails) isEqualTo 0;
missionNamespace setVariable ["webui_selfTestVerdict", ["red", "green"] select _green];
missionNamespace setVariable ["webui_selfTestFails", _fails];

private _skipped = 0;
private _lines = "";
{
    _x params ["_n", "_st", "_d"];
    if (_st isEqualTo 2) then { _skipped = _skipped + 1; };
    _lines = _lines + format ["<br/><t color='%1'>%2</t> %3",
        ["#e35b5b", "#38e1c4", "#c9a24a"] select _st,
        ["FAIL", "PASS", "SKIP"] select _st, _n];
} forEach _results;

private _clampNote = "";
if (_clamp isEqualTo "clamped") then {
    _clampNote = format ["<br/><br/><t color='#c9e21a'>NOTE frame delivery is CLAMPED (%1 fps).</t> Pages will look frozen on this client. Launch through Steam -- FINDINGS 1. Not an install fault.", _clampFps toFixed 1];
};

private _ran = (count _results) - _skipped;
hint parseText format [
    "<t size='1.2' color='%1'>WEBUI SELF TEST: %2</t><br/><t color='#7f93a6'>%3 of %4 checks passed%5</t>%6%7",
    ["#e35b5b", "#38e1c4"] select _green,
    ["RED", "GREEN"] select _green,
    _ran - (count _fails), _ran,
    if (_skipped > 0) then { format [", %1 SKIPPED", _skipped] } else { "" },
    _lines, _clampNote
];

diag_log format ["[WEBUI-TEST] ================ VERDICT: %1  (%2/%3 passed, %4 skipped) ================",
    ["RED", "GREEN"] select _green, _ran - (count _fails), _ran, _skipped];
if (!_green) then { diag_log format ["[WEBUI-TEST] failed: %1", _fails]; };
diag_log format ["[WEBUI-TEST] clamp=%1 bootPath=%2 signal=%3 readyIn=%4s",
    _clamp, _bootPath, _signal, if (_delta >= 0) then { _delta toFixed 3 } else { "n/a" }];

_green
