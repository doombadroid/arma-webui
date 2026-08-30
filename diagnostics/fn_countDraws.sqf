// SPDX-License-Identifier: MIT
/*
    fn_countDraws.sqf -- count the control's "Draw" events over a window.

    CT_WEBBROWSER raises Draw once per browser frame, so this is the ground
    truth for whether the engine is painting the page at all -- as opposed to
    what the page believes about itself, which can differ by an order of
    magnitude. Attaches its own handler and removes it again, so callers can
    sample repeatedly without bookkeeping.

    Returns frames per second, or -1 when NO SAMPLE was taken -- either the
    control died during the window, or another Draw sample was already running
    on it and this one was refused (the webui_drawBusy guard; the automatic
    clamp check takes that slot on the first page of every session). -1 is never
    a rate of zero, and callers must not print it as one.

    Usage (scheduled only -- it sleeps):
            private _fps = [_ctrl, "idle", 5] call webui_fnc_countDraws;
*/
params [["_ctrl", controlNull, [controlNull]], ["_label", "", [""]], ["_secs", 5, [0]]];
// uiSleep below needs a scheduler; unscheduled it raises rather than waiting.
if (!canSuspend) exitWith { diag_log "[WEBUI-DRAW] needs a scheduled context -- spawn the caller"; -1 };
if (isNull _ctrl) exitWith { -1 };

// PER-CALL COUNTER, and one sample at a time. This used to write into a single
// shared "webui_draws" slot on the control, and webui_fnc_clampCheck samples
// the same control automatically at ready+2s for 3s on the first page of every
// session -- which is almost exactly when webui_fnc_awaitPage hands a control
// to a diagnostic. Two samplers then attached two Draw handlers and both
// counted every draw into one slot, so drawRate reported ~38 fps idle where
// FINDINGS 1 says 0.6, and clampCheck computed its player-facing verdict from a
// counter an unrelated caller had reset mid-window.
if (_ctrl getVariable ["webui_drawBusy", false]) exitWith {
    diag_log format ["[WEBUI-DRAW] %1: REFUSED -- another sample is already running on this control (it would corrupt both)", _label];
    -1
};
_ctrl setVariable ["webui_drawBusy", true];

private _seq = (uiNamespace getVariable ["WEBUI_drawSeq", 0]) + 1;
uiNamespace setVariable ["WEBUI_drawSeq", _seq];
private _key = format ["webui_draws_%1", _seq];
_ctrl setVariable [_key, 0];

// The key is baked into the handler because ctrlAddEventHandler takes no args,
// and reading it back off the control would reintroduce the shared slot.
private _eh = _ctrl ctrlAddEventHandler ["Draw", compile format ["
    params ['_c'];
    _c setVariable ['%1', (_c getVariable ['%1', 0]) + 1];
", _key]];

private _t0 = diag_tickTime;
uiSleep _secs;
private _elapsed = (diag_tickTime - _t0) max 0.001;

// The control can die DURING the sleep, and that has to stay distinguishable
// from a rate of zero. getVariable on controlNull returns the alt-syntax
// default, so a dead control silently yielded _n = 0 and a rate of 0.0 -- a
// number every caller then read as a real measurement. webui_fnc_clampCheck
// tests for the -1 sentinel and could therefore never see it: it filed
// "clamped" and told a healthy Steam-launched player to relaunch, purely
// because they closed the dialog inside the sample window.
if (isNull _ctrl) exitWith {
    diag_log format ["[WEBUI-DRAW] %1: control died mid-sample after %2s -- no rate",
        _label, _elapsed toFixed 1];
    -1
};

private _n = _ctrl getVariable [_key, 0];
_ctrl ctrlRemoveEventHandler ["Draw", _eh];
_ctrl setVariable [_key, nil];          // do not leave a counter per sample behind
_ctrl setVariable ["webui_drawBusy", false];

private _fps = _n / _elapsed;
diag_log format ["[WEBUI-DRAW] %1: %2 draws / %3s = %4 fps",
    _label, _n, _elapsed toFixed 1, _fps toFixed 1];
_fps
