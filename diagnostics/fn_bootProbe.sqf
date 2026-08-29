// SPDX-License-Identifier: MIT
/*
    fn_bootProbe.sqf -- why is this page slow to show data?

    WHY THIS EXISTS. A page that renders instantly and then sits empty for most
    of a second is the most-reported and least-diagnosable failure this library
    has, because every branch that produces it looks identical from the outside.
    The bridge has to reach the page before anything queued in webui_fnc_exec
    can be delivered, and it can get there four different ways with very
    different timings. Which one won is the whole answer, and until this file
    existed the only record of it was an RPT line -- useless when the affected
    client belongs to someone else's server and you cannot get their logs.

    So this reports ON SCREEN, via hint, in a form somebody can screenshot and
    send you. The RPT copy is a bonus, not the point.

    IT NEEDS NOTHING FROM THE PAGE. The page-side facts are pulled with an
    injected statement calling a handler registered here, so this works against
    a page that has never heard of this diagnostic -- including a third party's
    page you cannot edit.

    READING THE RESULT. The two facts answer DIFFERENT questions, and the
    signal alone does not tell you whether the page has a working stub.

      boot path -- WHO DELIVERED THE BRIDGE. This is the actionable one.
        'stub' the page fetched webui.js itself with A3API.RequestFile. Fastest,
               and what every page should show.
        'sqf'  the page did not, so SQF's injector had to. Either the page has
               no self-boot stub or its stub is broken. Add or fix it --
               INSTALL.md step 6. This is the slow path and the one behind
               "screens take a moment to appear".

      ready signal -- WHICH SIGNAL WON THE RACE. Timing detail, not a verdict.
        'hello'      the injector's announcement arrived first. Note this can
                     also win on a page that HAS a stub, because the announcer
                     fires whenever the bridge exists and does not care who put
                     it there -- so 'hello' does NOT imply a missing stub. Read
                     the boot path for that.
        'message'    the page's own code spoke first.
        'pageloaded' the engine's load event was caught.
        'timer'      BROKEN. Nothing reached the page for 3 full seconds and the
                     queue drained on the backstop -- and a drain on that path
                     discards what it drains. Check allowedHTMLLoadURIs covers
                     the page's path. Then check whether SQF's injector died:
                     in the RPT, an "[WEBUI] inject: loadFile ..." line with NO
                     "inject: webui.js N bytes" line after it means loadFile was
                     refused and killed the thread (FINDINGS 11). There is no
                     error line for this -- the refusal is uncatchable, so the
                     MISSING follow-up line is the entire signal.

    Usage:  [] spawn webui_fnc_bootProbe;      // arm, then open a page
            [_ctrl] spawn webui_fnc_bootProbe; // a page that is already open
*/

params [["_ctrl", controlNull, [controlNull]]];
if (!canSuspend) exitWith { diag_log "[WEBUI-BOOT] needs a scheduled context -- spawn it"; false };

// uiNamespace WEBUI_ctrl is a single slot written by every fn_init and NEVER
// cleared, so "wait for it to be non-null" adopts whatever was open last --
// including an RscTitles browser overlay, which Esc does not close and which a
// dialog opening does not close either. That control is already ready, so the
// probe would sail straight past its gates and report the OVERLAY's boot as the
// boot of the page the operator opens next. Wait for the slot to CHANGE.
private _before = controlNull;
if (isNull _ctrl) then {
    _before = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
    if (!isNull _before) then {
        diag_log "[WEBUI-BOOT] a page is already live -- waiting for the NEXT page to open";
    };
    diag_log "[WEBUI-BOOT] armed -- open a page now (waiting up to 60s)";
    private _armDeadline = diag_tickTime + 60;
    waitUntil {
        uiSleep 0.25;
        _ctrl = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
        (!isNull _ctrl && { _ctrl isNotEqualTo _before }) || { diag_tickTime > _armDeadline }
    };
};
if (isNull _ctrl || { _ctrl isEqualTo _before }) exitWith {
    diag_log "[WEBUI-BOOT] no page opened within the arming window -- nothing measured";
    hint parseText ("<t size='1.1' color='#c9e21a'>WEBUI BOOT PROBE</t><br/>"
        + "<t color='#dfe8f0'>No page opened within 60s -- nothing measured.</t>");
    false
};

// Facts the page can report about itself. Registered on the control, so the
// injected statement below can reach it without the page cooperating.
[_ctrl, "__bootFacts", {
    params [["_path", "?", [""]], ["_bootAt", -1, [0]], ["_now", -1, [0]],
            ["_state", "?", [""]], ["_haveApi", false, [false]]];
    uiNamespace setVariable ["WEBUI_bootFacts", [_path, _bootAt, _now, _state, _haveApi]];
    true
}] call webui_fnc_on;

// Give the normal boot the same window it would get in real use before asking.
private _deadline = diag_tickTime + 4;
waitUntil {
    uiSleep 0.1;
    isNull _ctrl || { _ctrl getVariable ["webui_ready", false] } || { diag_tickTime > _deadline }
};
if (isNull _ctrl) exitWith { diag_log "[WEBUI-BOOT] control went away"; false };

uiNamespace setVariable ["WEBUI_bootFacts", nil];
_ctrl ctrlWebBrowserAction ["ExecJS",
    "(function(){try{ if(!window.WEBUI) return;"
  + " WEBUI.call('__bootFacts',[String(WEBUI.bootPath||'?'),"
  + " Math.round(WEBUI.bootAt||-1), Math.round(performance.now()),"
  + " String(document.readyState), (typeof A3API!=='undefined')]);"
  + " }catch(e){}})();"];

// webui.js gives the reply a 10s DEFAULT_TIMEOUT, so a 3s wait here can print
// "never answered" while the answer is still legitimately in flight -- most
// likely on exactly the frame-clamped client this probe exists to serve.
private _factDeadline = diag_tickTime + 11;
waitUntil {
    uiSleep 0.1;
    !isNil { uiNamespace getVariable "WEBUI_bootFacts" } || { diag_tickTime > _factDeadline }
};

// ------------------------------------------------------------------ report --
private _ready   = _ctrl getVariable ["webui_ready", false];
private _signal  = _ctrl getVariable ["webui_readySignal", "none"];
private _initAt  = _ctrl getVariable ["webui_initAt", -1];
private _readyAt = _ctrl getVariable ["webui_readyAt", -1];
private _delta   = if (_initAt >= 0 && _readyAt >= 0) then { _readyAt - _initAt } else { -1 };
private _facts   = uiNamespace getVariable ["WEBUI_bootFacts", []];

private _path = "unknown (page never answered)";
if (count _facts >= 1) then { _path = _facts select 0; };

// The verdict is the point. Anything that is not a fast 'hello'/'pageloaded'/
// 'message' is a real finding, so say so rather than printing numbers and
// leaving the reader to know what good looks like.
private _answered = (count _facts >= 1);
private _verdict = switch (true) do {
    case (!_ready):                    { "BROKEN -- the bridge never reached the page" };
    case (_signal isEqualTo "timer"):  { "BROKEN -- drained on the 3s backstop, nothing reached the page" };
    // Readiness marked but the page never answered the fact probe: the bridge
    // was declared up without actually landing. Printing "OK" here would be the
    // worst possible answer, so it is called out on its own.
    case (!_answered):                 { "SUSPECT -- marked ready, but the page never answered" };
    // A control from a build predating this diagnostic has no webui_initAt, so
    // _delta is -1. Without this the default branch prints "OK -- -1.00s".
    case (_delta < 0):                 { "UNKNOWN -- this build records no init timestamp" };
    case (_delta > 0.25):              { format ["SLOW -- %1s to first data", _delta toFixed 2] };
    default                            { format ["OK -- %1s to first data", _delta toFixed 2] };
};

// APPENDED, never assigned twice. Both rules can match at once (a late HELLO
// arriving after the backstop has already stamped "timer" gives path=sqf AND
// signal=timer), and an assignment there drops the advice that is correct in
// favour of one telling the reader to audit a whitelist the same hint has just
// proved is fine.
private _advice = "";
if (_path isEqualTo "sqf") then {
    _advice = _advice + "<br/>Page has no working self-boot stub (INSTALL.md step 6). Adding it is the single biggest win.";
};
if (_signal isEqualTo "timer") then {
    _advice = _advice + "<br/>Nothing reached the page for 3s. Check allowedHTMLLoadURIs covers this page's path, then check the RPT for an 'inject: loadFile' line with no 'webui.js N bytes' line after it -- that missing line means loadFile was refused (FINDINGS 11).";
};
if (!_answered) then {
    _advice = _advice + "<br/>The page never answered the probe, so readiness was marked without the bridge landing.";
};

private _txt = format [
    "<t size='1.1' color='#c9e21a'>WEBUI BOOT PROBE</t><br/>"
  + "<t color='#dfe8f0'>%1</t><br/><br/>"
  + "ready signal: <t color='#38e1c4'>%2</t><br/>"
  + "init -> ready: <t color='#38e1c4'>%3 s</t><br/>"
  + "page boot path: <t color='#38e1c4'>%4</t><br/>"
  + "A3API bound: <t color='#38e1c4'>%5</t>%6",
    _verdict, _signal,
    if (_delta >= 0) then { _delta toFixed 3 } else { "n/a" },
    _path,
    if (count _facts >= 5) then { str (_facts select 4) } else { "unknown" },
    _advice
];

hint parseText _txt;
diag_log format ["[WEBUI-BOOT] %1 | signal=%2 delta=%3s bootPath=%4 facts=%5",
    _verdict, _signal, if (_delta >= 0) then { _delta toFixed 3 } else { "n/a" }, _path, _facts];

[_verdict, _signal, _delta, _path]
