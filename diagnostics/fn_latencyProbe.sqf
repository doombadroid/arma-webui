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
             design, so it does not ride the payload ladder. API.md quotes it
             at ~0.7x call() -- and carries a caveat that every figure in
             FINDINGS 5 was captured at an unrecorded client uptime on a
             single-precision clock, so this leg re-measures rather than
             confirms.

    The page half reports its own statistics back over WEBUI.call, so both
    clocks appear in the output and the reader can attribute any gap.

    Output: [WEBUI-LAT] rows, one per (leg, size, side); a BRACKETED MEAN row per
    leg and size (whose error is one clock quantum divided by the iteration
    count, unlike the per-iteration figures); and one derived row per size giving
    leg B's median minus leg A's. The clock's own quantum is printed first,
    because on a long-lived client it can exceed the numbers below.
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
    // True median. select [floor(n/2)] is the UPPER median on an even n -- for
    // the n=20 runs behind FINDINGS 5 that is the 11th smallest, biased high,
    // reported under a label that says "med".
    private _n = count _vs;
    private _med = if (_n % 2 isEqualTo 1) then {
        _vs select (floor (_n / 2))
    } else {
        ((_vs select (_n / 2 - 1)) + (_vs select (_n / 2))) / 2
    };
    [_vs select 0, _med, _vs select (_n - 1)]
};
// THE CLOCK BOUNDS EVERY NUMBER BELOW. diag_tickTime is single precision and
// coarsens with uptime (BIKI): ~0.24 ms after an hour, ~7.8 ms after a day,
// ~62 ms after a week. A per-iteration sample is a difference of two such reads,
// so on a long-lived client these medians are quantisation, not latency -- and
// the rows print to 0.1 ms. Not recoverable by subtracting a baseline, so the
// probe reports the quantum and pairs each leg with a bracketed mean whose error
// is one quantum over N iterations.
private _quantumMs = (2 ^ ((floor (ln (diag_tickTime max 1) / ln 2)) - 23)) * 1000;
diag_log format ["[WEBUI-LAT] clock: diag_tickTime quantum is %1 ms at this uptime -- per-iteration figures below are only meaningful well above it; prefer the bracketed mean when they are not",
    _quantumMs toFixed 4];
if (_quantumMs > 1) then {
    diag_log "[WEBUI-LAT] WARNING: the clock is coarser than 1 ms. Restart the game before quoting these rows into docs/FINDINGS.md section 5.";
    systemChat "latency probe: clock is coarse (long uptime) -- see RPT before trusting the numbers";
};

private _logRow = {
    params ["_leg", "_size", "_side", "_n", "_s"];
    // toFixed 0 on the size: Arma's default number->string is 6 significant
    // figures, so the 4194304 rung printed as 4.19430e+006 while other lines
    // printed it in full -- the same rung under two different labels in one
    // report. toFixed never produces scientific notation.
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
    // _webuiCtrl is the control this handler fired on, supplied by fn_init.
    // This used to read uiNamespace WEBUI_ctrl -- the last control initialised
    // -- so with a second browser control live the stamp landed on the wrong
    // one and every rung reported FAIL.
    if (!isNull _webuiCtrl) then { _webuiCtrl setVariable ["webui_latT1", diag_tickTime] };
    true
}] call webui_fnc_on;

// One map per leg, named for the leg it holds. The single map that used to exist
// was called _legA but was declared inside the leg B block and filled with leg
// B's medians, so the "derived row" had nothing to subtract from -- which is why
// it only ever printed a sentence.
private _medA = createHashMap;   // size -> median, leg A (execjs-echo)
private _medB = createHashMap;   // size -> median, leg B (fnc-call)

systemChat "latency probe: leg A (event-stamped ExecJS echo)";
{
    private _size = _x;
    private _blob = [_size] call _payload;
    private _js = format ["(function(){ var p = '%1'; window.__latRx = performance.now(); A3API.SendConfirm(JSON.stringify(['ASK','latPong',[]])); })();", _blob];
    private _vals = [];
    private _fail = false;
    // one pair of reads around the WHOLE run: the quantisation error is then
    // divided by _ITERS instead of applying to every individual sample
    private _bracket0 = diag_tickTime;
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
    private _bracketMs = ((diag_tickTime - _bracket0) * 1000) / (_ITERS max 1);
    if (_fail) then {
        diag_log format ["[WEBUI-LAT] leg=execjs-echo size=%1 FAIL (timeout or control gone)", _size toFixed 0];
    } else {
        diag_log format ["[WEBUI-LAT] leg=execjs-echo size=%1 BRACKETED MEAN %2ms over %3 iters (quantum %4ms)",
            _size toFixed 0, _bracketMs toFixed 2, _ITERS, _quantumMs toFixed 4];
        private _s = [_vals] call _stats;
        ["execjs-echo", _size, "sqf-event", count _vals, _s] call _logRow;
        _medA set [_size, _s select 1];
        // one-way: the honest ceiling of what two unsynchronised clocks allow
        diag_log format ["[WEBUI-LAT] leg=execjs-oneway size=%1 bound: <=%2ms; ~%3ms if symmetric (ASSUMED, not measured)",
            _size toFixed 0, (_s select 0) toFixed 1, ((_s select 0) / 2) toFixed 1];
    };
} forEach _SIZES;

// -------------------------------------------------------- leg B: fnc-call --
// The real SQF-side API, polling wait included. The OUTBOUND ExecJS leg carries
// the full payload; the page acknowledges with its byte count. Echoing it back
// would send it through the 10240-byte-capped direction, truncating every rung
// above 1 KB and recording it as a timeout -- measuring the cap, not the trip.
{
    private _size = _x;
    private _blob = [_size] call _payload;
    private _vals = [];
    private _fail = false;
    private _bracket0 = diag_tickTime;   // same bracketing as leg A
    for "_i" from 1 to _ITERS do {
        private _t0 = diag_tickTime;
        private _r = [_ctrl, "latEcho", [_blob], _TIMEOUT] call webui_fnc_call;
        // the page returns the byte count it received, so a short read is
        // visible as a wrong number rather than as a silent success
        if (isNil "_r") exitWith { _fail = true };
        if (_r isEqualType 0 && { _r isNotEqualTo _size }) exitWith {
            diag_log format ["[WEBUI-LAT] leg=fnc-call size=%1 FAIL -- page received %2 chars, not %3 (outbound truncation?)",
                _size toFixed 0, _r, _size toFixed 0];
            _fail = true
        };
        _vals pushBack ((diag_tickTime - _t0) * 1000);
    };
    private _bracketMs = ((diag_tickTime - _bracket0) * 1000) / (_ITERS max 1);
    if (_fail) then {
        diag_log format ["[WEBUI-LAT] leg=fnc-call size=%1 FAIL (timeout)", _size toFixed 0];
    } else {
        diag_log format ["[WEBUI-LAT] leg=fnc-call size=%1 BRACKETED MEAN %2ms over %3 iters (quantum %4ms)",
            _size toFixed 0, _bracketMs toFixed 2, _ITERS, _quantumMs toFixed 4];
        private _s = [_vals] call _stats;
        ["fnc-call", _size, "sqf-poll", count _vals, _s] call _logRow;
        _medB set [_size, _s select 1];
    };
} forEach _SIZES;

// ---------------------------------------------------- legs C + D: page side --
// Driven and timed entirely in the page; results come back over the bridge so
// the RPT holds both clocks. The 4 MB return leg rides ExecJS (_resolve), the
// same path FINDINGS §5 originally measured.
[_ctrl, "latReport", {
    params [["_leg", "", [""]], ["_size", 0, [0]], ["_vals", [], [[]]]];
    if (!isNull _webuiCtrl) then {
        private _done = _webuiCtrl getVariable ["webui_latReports", []];
        _done pushBack [_leg, _size, _vals];
        _webuiCtrl setVariable ["webui_latReports", _done];
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
// toFixed 0, not the default conversion: Arma renders numbers with 6
// significant figures by default, so 4194304 reached the page as 4.19430e+006
// and the top ladder rung measured a different payload than the SQF legs did.
private _sizesJs = (_SIZES apply { _x toFixed 0 }) joinString ",";
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
        diag_log format ["[WEBUI-LAT] leg=%1 size=%2 FAIL (page reported no samples)", _leg, _size toFixed 0];
    } else {
        [_leg, _size, "page", count _vals, [_vals] call _stats] call _logRow;
    };
} forEach (_ctrl getVariable ["webui_latReports", []]);

// -------------------------------------------------------------- derived row --
// fnc-call minus the event-stamped echo at the same size = polling wait plus
// the reply/_resolve path. If the historical 618 ms lives anywhere, it is here.
{
    private _size = _x;
    if ((_size in keys _medA) && { _size in keys _medB }) then {
        private _dA = _medA get _size;
        private _dB = _medB get _size;
        diag_log format ["[WEBUI-LAT] derived: size=%1 fnc-call med %2ms - execjs-echo med %3ms = %4ms scheduler + reply-path overhead",
            _size toFixed 0, _dB toFixed 2, _dA toFixed 2, (_dB - _dA) toFixed 2];
    };
} forEach _SIZES;

// Take the probe's handlers back off the operator's live page. latServe in
// particular stays callable and allocates an arbitrary-size string on demand,
// for the rest of the page's life, on a screen they have gone back to using.
{ [_ctrl, _x] call webui_fnc_off; } forEach ["latPong", "latReport", "latServe"];
_ctrl setVariable ["webui_latT1", nil];
_ctrl setVariable ["webui_latReports", nil];

diag_log "[WEBUI-LAT] done -- paste the rows above into docs/FINDINGS.md section 5";
systemChat "latency probe done -- results in the RPT under [WEBUI-LAT]";
