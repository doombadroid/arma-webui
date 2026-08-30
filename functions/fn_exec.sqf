// SPDX-License-Identifier: MIT
/*
    fn_webExec.sqf -- run JavaScript in a page, holding it if the page is not up.

    The BIKI is explicit that before the control's PageLoaded event "the page
    might not be ready to receive JavaScript and may drop ExecJS requests".
    Dropped silently, of course. So everything that talks to a page goes through
    here.

    THE GATE IS THE BRIDGE, NOT PageLoaded. A statement is held until
    window.WEBUI is PROVEN to exist -- which only a HELLO, or any other inbound
    message from the page, establishes. PageLoaded and the 3 s backstop mark the
    page as loaded and deliberately leave the queue HELD, because every queued
    statement is guarded by `window.WEBUI && ...` and firing them into a
    document without the bridge turns "late" into "permanently lost". The drain
    lives in fn_init's _markReady and runs only on those two proving signals.

    Usage:  [_ctrl, "console.log('hi')"] call webui_fnc_exec;
*/

params [["_ctrl", controlNull, [controlNull]], ["_js", "", [""]]];
if (isNull _ctrl) exitWith { false };
if (_js isEqualTo "") exitWith { false };

// webui_BRIDGE, not webui_ready: readiness means the page loaded, which is not
// the same as window.WEBUI existing. Sending directly on the strength of
// readiness alone dropped the statement into a document with no bridge, where
// its `window.WEBUI && ...` guard silently short-circuited.
if (_ctrl getVariable ["webui_bridge", false]) exitWith {
    _ctrl ctrlWebBrowserAction ["ExecJS", _js];
    true
};

private _q = _ctrl getVariable ["webui_queue", []];
// A page that never loads must not grow this without bound.
if (count _q >= 200) exitWith {
    // Say so in the return value. This used to drop and still report true, so
    // a caller pushing at 10 Hz against a page that took 25 s to come up was
    // told every one of its discarded statements had been accepted.
    diag_log format ["[WEBUI] exec queue full (%1) -- dropping, page never became ready", count _q];
    false
};
// NO setVariable. An SQF array variable is a REFERENCE (BIKI, Array: "An array
// set through setVariable does not need to be assigned again if you modify it by
// reference"), so pushBack already mutates the stored queue. Writing it back was
// not merely redundant, it was a race: the read above and the write here are
// separate statements, so a drain landing between them had its fresh empty queue
// overwritten by this stale array -- resurrecting every statement the drain had
// just sent. The drain now clears the SAME array with resize rather than
// installing a new one, so there is exactly one queue object and no reference to
// get stale.
_q pushBack _js;

// RE-CHECK THE BRIDGE. The direct-send test above and this append are separate
// statements, so the bridge can be proven in between -- and the drain that
// proves it has already run and will not run again. The statement would then sit
// in the queue with nothing left to revisit it, silently, for the life of the
// control. If we lost that race, send it now.
if (_ctrl getVariable ["webui_bridge", false]) then {
    private _i = _q find _js;
    if (_i >= 0) then {
        _q deleteAt _i;
        _ctrl ctrlWebBrowserAction ["ExecJS", _js];
        diag_log "[WEBUI] exec: bridge came up mid-append -- sent directly rather than stranding the statement";
    };
};
true
