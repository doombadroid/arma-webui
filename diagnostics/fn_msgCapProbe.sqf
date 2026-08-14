// SPDX-License-Identifier: MIT
/*
    fn_msgCapProbe.sqf -- where exactly does the page -> SQF channel truncate?

    WHY THIS EXISTS. fn_latencyProbe's leg B failed at every rung >= 64 KB, and
    the RPT said why: the JSDialog event delivered `["REPLY",21,true,"xxx...`
    -- valid JSON cut off mid-string. The engine truncates the message string
    somewhere between 1 KB (a ~1044-char reply passed 20/20) and 64 KB (every
    attempt arrived broken). The OUTBOUND direction has no such limit: ExecJS
    carried 4 MB payloads in the same session. A page author needs the exact
    inbound number -- it is the threshold above which a reply must be chunked
    or redesigned to flow SQF -> page -- and "somewhere between 1 KB and 64 KB"
    is not a threshold, it is a shrug.

    WHAT IT DOES. Binary search on the message length, one channel at a time:

      alert    A3API.SendAlert(json)    -- the CALL / REPLY envelope carrier
      confirm  A3API.SendConfirm(json)  -- the ASK envelope carrier

    Each round injects page JS that builds an envelope padded to EXACTLY the
    probed total length and sends it. If the receipt handler fires, the length
    fits; if the round times out (the truncated JSON was dropped by the
    malformed-request guard in fn_init), it does not. The bisect converges to
    one character, then the boundary is re-tested 3x on each side -- a cap
    that wobbles under load would show up here as a mixed verdict, and a mixed
    verdict is logged as such rather than averaged away.

    Lengths are TOTAL message characters (the whole JSON string handed to
    SendAlert/SendConfirm), ASCII payload -- whether the engine counts UTF-16
    units or bytes is not distinguishable with ASCII and is noted in the row.

    Output: [WEBUI-CAP] rows -- one per bisect round, then the verdict pair.

    Arm first, then open a page:  [] spawn webui_fnc_msgCapProbe;
*/
if (!canSuspend) exitWith { diag_log "[WEBUI-CAP] use spawn"; };

private _ctrl = [] call webui_fnc_awaitPage;
if (isNull _ctrl) exitWith {};

private _WAIT = 3;          // seconds to decide "did not arrive"
private _LO   = 1024;       // known-good total length (leg B, 20/20)
private _HI   = 65536;      // known-bad  total length (leg B, 0/20)

// receipt handler: stamps the length the ENVELOPE claims, which the page set
// to the true sent length. Rides the ASK path for confirm rounds and the CALL
// path for alert rounds -- i.e. each channel verifies itself, no crossover.
[_ctrl, "capRx", {
    params [["_n", -1, [0]]];
    private _c = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
    if (!isNull _c) then { _c setVariable ["webui_capRx", _n] };
    true
}] call webui_fnc_on;

// The ASK envelope is ["ASK", name, args] and the CALL envelope is
// ["CALL", seq, name, args]; both are built page-side as a 4-element array
// ["ASK"|"CALL", "capRx", [len], padding] -- fn_init's ASK case reads elements
// 1..2 and the CALL case would misread it, so the alert channel sends the CALL
// shape explicitly:
private _mkAlert = "
(function () {
  var want = %1;
  var mk = function (pad) { return JSON.stringify(['CALL', 999000, 'capRx', [want, 'x'.repeat(pad)]]); };
  var base = mk(0).length;
  var msg = mk(Math.max(0, want - base));
  if (msg.length !== want) { return; }
  A3API.SendAlert(msg);
})();";
private _mkAsk = "
(function () {
  var want = %1;
  var mk = function (pad) { return JSON.stringify(['ASK', 'capRx', [want, 'x'.repeat(pad)]]); };
  var base = mk(0).length;
  var msg = mk(Math.max(0, want - base));
  if (msg.length !== want) { return; }
  A3API.SendConfirm(msg);
})();";
private _tryRaw = {
    params ["_ctrl", "_tpl", "_len", "_wait"];
    _ctrl setVariable ["webui_capRx", -1];
    _ctrl ctrlWebBrowserAction ["ExecJS", format [_tpl, _len]];
    private _deadline = diag_tickTime + _wait;
    waitUntil { (_ctrl getVariable ["webui_capRx", -1]) > -1 || { diag_tickTime > _deadline } || { isNull _ctrl } };
    (_ctrl getVariable ["webui_capRx", -1]) isEqualTo _len
};

{
    _x params ["_label", "_tpl"];
    if (isNull _ctrl) exitWith {};
    systemChat format ["cap probe: bisecting %1 channel", _label];

    // trust nothing: re-verify both bracket ends on THIS channel first
    private _lo = _LO;
    private _hi = _HI;
    if !([_ctrl, _tpl, _lo, _WAIT] call _tryRaw) exitWith {
        diag_log format ["[WEBUI-CAP] chan=%1 FAIL: known-good bracket %2 did not arrive -- aborting this channel", _label, _lo];
    };
    if ([_ctrl, _tpl, _hi, _WAIT] call _tryRaw) exitWith {
        diag_log format ["[WEBUI-CAP] chan=%1 %2 arrived intact -- no cap below %2, widen _HI and rerun", _label, _hi];
    };

    while { _hi - _lo > 1 } do {
        private _mid = floor ((_lo + _hi) / 2);
        private _ok = [_ctrl, _tpl, _mid, _WAIT] call _tryRaw;
        diag_log format ["[WEBUI-CAP] chan=%1 len=%2 %3", _label, _mid, ["TRUNCATED", "ok"] select _ok];
        if (_ok) then { _lo = _mid } else { _hi = _mid };
        if (isNull _ctrl) exitWith {};
    };
    if (isNull _ctrl) exitWith {};

    // boundary confidence: 3x each side. A wobble prints as a wobble.
    private _okLo = 0;
    private _okHi = 0;
    for "_i" from 1 to 3 do {
        if ([_ctrl, _tpl, _lo, _WAIT] call _tryRaw) then { _okLo = _okLo + 1 };
        if ([_ctrl, _tpl, _hi, _WAIT] call _tryRaw) then { _okHi = _okHi + 1 };
    };
    if (_okLo isEqualTo 3 && { _okHi isEqualTo 0 }) then {
        diag_log format ["[WEBUI-CAP] chan=%1 VERDICT: max intact message = %2 chars (ASCII; %3 truncated, both retested 3x)", _label, _lo, _hi];
    } else {
        diag_log format ["[WEBUI-CAP] chan=%1 VERDICT UNSTABLE: len=%2 ok %3/3, len=%4 ok %5/3 -- cap moves under load, treat %2 as optimistic", _label, _lo, _okLo, _hi, _okHi];
    };
} forEach [["alert", _mkAlert], ["ask", _mkAsk]];

diag_log "[WEBUI-CAP] done -- paste the VERDICT rows into docs/FINDINGS.md section 5";
systemChat "cap probe done -- results in the RPT under [WEBUI-CAP]";
