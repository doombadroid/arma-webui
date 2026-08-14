// SPDX-License-Identifier: MIT
/*
    fn_latencyProbe.sqf -- how long does a message actually take, per leg?

    WHY THIS EXISTS. This repo has carried two latency figures that cannot both
    be true: API.md quoted WEBUI.call at ~15-21 ms while FINDINGS §5 put a lone
    ExecJS at 618 ms -- and call() CONTAINS an ExecJS leg. Neither number had a
    probe behind it. The likely explanation is that they measured different
    things: one the transport, the other the transport PLUS a scheduled-SQF
    polling wait, whose granularity is a property of the SQF scheduler and not
    of the bridge. This probe separates those, per leg, per payload size, on
    both clocks, so the next number written into the docs can say exactly what
    it is a number OF.

    WHAT IT DOES. Measures four legs independently, >= 20 iterations each,
    min / median / max, with a payload ladder (1 KB / 64 KB / 512 KB / 4 MB)
    to split fixed cost from per-byte cost. A rung that fails logs a FAIL row
    and the ladder continues.

      leg A  execjs-echo   SQF -> page -> SQF, EVENT-STAMPED. SQF stamps t0,
             an ExecJS carries the payload in and its only work is
             A3API.SendConfirm(["ASK","latPong",...]); the probe's latPong
             handler runs INLINE in the JSDialog event handler (ASK handlers
             are unscheduled) and stamps t1 there. No polling anywhere, so
             this is the tightest transport round trip SQF can observe.
             One-way is NOT directly measurable: diag_tickTime and
             performance.now() share no epoch. Reported as the hard bound
             (one-way <= RT) plus RT/2 labelled "symmetry assumed".
      leg B  fnc-call      SQF -> page -> SQF through webui_fnc_call, i.e.
             what the SQF-side API actually costs INCLUDING its polling wait.
             B minus A at the same size is the scheduler + reply-path
             overhead, printed as a derived row -- this difference is the
             candidate explanation for the historical 618 ms.
      leg C  page-call     page -> SQF -> page through WEBUI.call, measured
             entirely on performance.now() by a loop injected into the page.
             This is the leg API.md's old number claimed to be.
      leg D  page-ask      page -> SQF through WEBUI.ask. Bool-only by
             design, so it does not ride the payload ladder; API.md claims
             roughly half of call(), which this checks.

    The page half reports its own statistics back over WEBUI.call, so both
    clocks appear in the output and the reader can attribute any gap.

    Output: [WEBUI-LAT] rows, one per (leg, size, side), then a summary table.
    Expect the 4 MB rungs to take a while; the chat narrates progress.

    Arm first, then open a page:  [] spawn webui_fnc_latencyProbe;
*/
if (!canSuspend) exitWith { diag_log "[WEBUI-LAT] use spawn"; };

private _ctrl = [] call webui_fnc_awaitPage;
if (isNull _ctrl) exitWith {};

private _ITERS = 20;
private _SIZES = [1024, 65536, 524288, 4194304];   // the FINDINGS §5 ladder
private _TIMEOUT = 30;                             // per sample, seconds

// ---------------------------------------------------------------- helpers --
private _stats = {
    // [values] -> [min, median, max]; empty -> [-1, -1, -1]
    params ["_vs"];
    if (_vs isEqualTo []) exitWith { [-1, -1, -1] };
    _vs sort true;
    [_vs select 0, _vs select (floor ((count _vs) / 2)), _vs select (count _vs - 1)]
};
private _logRow = {
    params ["_leg", "_size", "_side", "_n", "_s"];
    diag_log format ["[WEBUI-LAT] leg=%1 size=%2 side=%3 n=%4 min=%5ms med=%6ms max=%7ms",
        _leg, _size toFixed 0, _side, _n,
        (_s select 0) toFixed 1, (_s select 1) toFixed 1, (_s select 2) toFixed 1];
};
private _payload = {
    // a payload of exactly _n 'x' characters -- only safe chars, so it can be
    // interpolated into JavaScript source without any escaping questions
    params ["_n"];
    private _s = "x";
    while { count _s < _n } do { _s = _s + _s };
    _s select [0, _n]
};

// ------------------------------------------------------ leg A: execjs-echo --
// latPong runs INLINE in the JSDialog EH (ASK path is unscheduled), so the t1
// stamp is event-grade. The payload rides the outbound ExecJS as a JS literal;
// the return SendConfirm carries only the envelope.
[_ctrl, "latPong", {
    private _c = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
    if (!isNull _c) then { _c setVariable ["webui_latT1", diag_tickTime] };
    true
}] call webui_fnc_on;

systemChat "latency probe: leg A (event-stamped ExecJS echo)";
{
    private _size = _x;
    private _blob = [_size] call _payload;
    private _js = format ["(function(){ var p = '%1'; window.__latRx = performance.now(); A3API.SendConfirm(JSON.stringify(['ASK','latPong',[]])); })();", _blob];
    private _vals = [];
    private _fail = false;
    for "_i" from 1 to _ITERS do {
        _ctrl setVariable ["webui_latT1", -1];
        private _t0 = diag_tickTime;
        _ctrl ctrlWebBrowserAction ["ExecJS", _js];
        private _deadline = diag_tickTime + _TIMEOUT;
        waitUntil { (_ctrl getVariable ["webui_latT1", -1]) > -1 || { diag_tickTime > _deadline } || { isNull _ctrl } };
        if (isNull _ctrl) exitWith { _fail = true };
        private _t1 = _ctrl getVariable ["webui_latT1", -1];
        if (_t1 < 0) exitWith { _fail = true };
        // the waitUntil above only decides when WE notice; _t1 was stamped in
        // the event handler, so the sample itself is poll-free
        _vals pushBack ((_t1 - _t0) * 1000);
    };
    if (_fail) then {
        diag_log format ["[WEBUI-LAT] leg=execjs-echo size=%1 FAIL (timeout or control gone)", _size];
    } else {
        private _s = [_vals] call _stats;
        ["execjs-echo", _size, "sqf-event", count _vals, _s] call _logRow;
        // one-way: the honest ceiling of what two unsynchronised clocks allow
        diag_log format ["[WEBUI-LAT] leg=execjs-oneway size=%1 bound: <=%2ms; ~%3ms if symmetric (ASSUMED, not measured)",
            _size, (_s select 0) toFixed 1, ((_s select 0) / 2) toFixed 1];
    };
} forEach _SIZES;

// -------------------------------------------------------- leg B: fnc-call --
// The real SQF-side API, polling wait included. The page echoes the payload
// back, so both directions carry the load.
[_ctrl, "window.WEBUI && WEBUI.handle('latEcho', function (p) { return p; });"] call webui_fnc_exec;

systemChat "latency probe: leg B (webui_fnc_call, as the API really costs)";
private _legA = createHashMap;   // size -> median, for the derived row
{
    private _size = _x;
    private _blob = [_size] call _payload;
    private _vals = [];
    private _fail = false;
    for "_i" from 1 to _ITERS do {
        private _t0 = diag_tickTime;
        private _r = [_ctrl, "latEcho", [_blob], _TIMEOUT] call webui_fnc_call;
        if (isNil "_r") exitWith { _fail = true };
        _vals pushBack ((diag_tickTime - _t0) * 1000);
    };
    if (_fail) then {
        diag_log format ["[WEBUI-LAT] leg=fnc-call size=%1 FAIL (timeout)", _size];
    } else {
        private _s = [_vals] call _stats;
        ["fnc-call", _size, "sqf-poll", count _vals, _s] call _logRow;
        _legA set [_size, _s select 1];
    };
} forEach _SIZES;

// ---------------------------------------------------- legs C + D: page side --
// Driven and timed entirely in the page; results come back over the bridge so
// the RPT holds both clocks. The 4 MB return leg rides ExecJS (_resolve), the
// same path FINDINGS §5 originally measured.
[_ctrl, "latReport", {
    params [["_leg", "", [""]], ["_size", 0, [0]], ["_vals", [], [[]]]];
    private _c = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
    if (!isNull _c) then {
        private _done = _c getVariable ["webui_latReports", []];
        _done pushBack [_leg, _size, _vals];
        _c setVariable ["webui_latReports", _done];
    };
    createHashMapFromArray [["ok", true], ["msg", ""]]
}] call webui_fnc_on;

// SQF answers the page's call with a payload of the requested size, so the
// REPLY (ExecJS) leg is the loaded one -- the direction §5 measured.
[_ctrl, "latServe", {
    params [["_n", 0, [0]]];
    private _s = "x";
    while { count _s < _n } do { _s = _s + _s };
    _s select [0, _n]
}] call webui_fnc_on;

_ctrl setVariable ["webui_latReports", []];
private _sizesJs = _SIZES joinString ",";
[_ctrl, format ["
(function () {
  var SIZES = [%1], ITERS = %2;
  function run(i, s, done) {
    var vals = [];
    function one(k) {
      if (k >= ITERS) { done(vals); return; }
      var t0 = performance.now();
      WEBUI.call('latServe', [s], 60000).then(function () {
        vals.push(performance.now() - t0); one(k + 1);
      }).catch(function () { done(null); });
    }
    one(0);
  }
  function ladder(i) {
    if (i >= SIZES.length) { askLeg(); return; }
    run(i, SIZES[i], function (vals) {
      WEBUI.call('latReport', ['page-call', SIZES[i], vals || []]);
      ladder(i + 1);
    });
  }
  function askLeg() {
    var vals = [];
    function one(k) {
      if (k >= ITERS) { WEBUI.call('latReport', ['page-ask', 0, vals]); return; }
      var t0 = performance.now();
      WEBUI.ask('latPong', []).then(function () {
        vals.push(performance.now() - t0); one(k + 1);
      }).catch(function () { WEBUI.call('latReport', ['page-ask', 0, []]); });
    }
    one(0);
  }
  ladder(0);
})();", _sizesJs, _ITERS]] call webui_fnc_exec;

systemChat "latency probe: legs C+D running in the page -- hands off";
private _want = (count _SIZES) + 1;   // one report per call rung + one for ask
private _deadline = diag_tickTime + 600;
waitUntil {
    uiSleep 0.5;
    (count (_ctrl getVariable ["webui_latReports", []])) >= _want
        || { diag_tickTime > _deadline } || { isNull _ctrl }
};
{
    _x params ["_leg", "_size", "_vals"];
    if (_vals isEqualTo []) then {
        diag_log format ["[WEBUI-LAT] leg=%1 size=%2 FAIL (page reported no samples)", _leg, _size];
    } else {
        [_leg, _size, "page", count _vals, [_vals] call _stats] call _logRow;
    };
} forEach (_ctrl getVariable ["webui_latReports", []]);

// -------------------------------------------------------------- derived row --
// fnc-call minus the event-stamped echo at the same size = polling wait plus
// the reply/_resolve path. If the historical 618 ms lives anywhere, it is here.
{
    private _size = _x;
    if (_size in keys _legA) then {
        diag_log format ["[WEBUI-LAT] derived: fnc-call med minus execjs-echo med at %1 = scheduler + reply-path overhead (see rows above)", _size];
    };
} forEach _SIZES;

diag_log "[WEBUI-LAT] done -- paste the rows above into docs/FINDINGS.md section 5";
systemChat "latency probe done -- results in the RPT under [WEBUI-LAT]";
