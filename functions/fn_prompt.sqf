// SPDX-License-Identifier: MIT
/*
    webui_fnc_prompt.sqf -- native text entry for web UI pages.

    Typed text reaches the DOM normally, so a real <input> in a page works and
    this is OPTIONAL. It exists for a native-looking prompt, and for when the
    browser is frozen.

    Shows an overlay in the SAME dialog as the browser -- a second dialog would
    fight over focus -- waits for OK/Cancel, and returns the string.

    Called from a page over the bridge:
        const name = await WEBUI.call("promptText", ["Rename gang", current, 24]);
        if (name !== null) { ... }          // null = cancelled

    Returns the entered string, or nil on cancel. Runs in a scheduled context
    (the bridge dispatcher spawns handlers), so waitUntil here is safe.
*/

params [
    ["_title",   "Enter text", [""]],
    ["_prefill", "",           [""]],
    ["_max",     64,           [0]]
];

disableSerialization;
// FIRST-RUN DEFAULTS, SET INDEPENDENTLY AND READ SAFELY -- both parts matter.
//
// This used to initialise BusY and Gen together behind one isNil check on Busy.
// Anything that set Busy without setting Gen therefore skipped the whole block
// and left Gen undefined, and reading an undefined variable inside
// `with uiNamespace do { ... }` does not yield nil -- it raises "Undefined
// variable in expression". The self-test hit exactly that and it also meant
// prompt_overlay.hpp's button handler could throw mid-click. Two variables
// behind one guard is one variable too many.
//
// getVariable-with-a-default cannot throw, and setting each from its own
// current value is idempotent.
uiNamespace setVariable ["WEBUI_promptBusy", uiNamespace getVariable ["WEBUI_promptBusy", false]];
uiNamespace setVariable ["WEBUI_promptGen",  uiNamespace getVariable ["WEBUI_promptGen",  0]];
// resolve the hosting display from the browser control published by
// webui_fnc_init, so this works for any dialog, not just the demo
private _webCtrl = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
if (isNull _webCtrl) exitWith { diag_log "[PROMPT] no web control registered"; nil };
private _display = ctrlParent _webCtrl;
if (isNull _display) exitWith { nil };

private _ids  = [937410, 937411, 937412, 937413, 937414, 937415];
private _edit = _display displayCtrl 937413;
if (isNull _edit) exitWith {
    diag_log "[PROMPT] overlay controls missing from the dialog";
    nil
};

// seed the field and title
(_display displayCtrl 937412) ctrlSetStructuredText parseText format [
    "<t size='1' font='RobotoCondensed' color='#c9e21a'>%1</t>", _title
];
_edit ctrlSetText (_prefill select [0, _max]);

// ONE OVERLAY, ONE PROMPT AT A TIME -- AND IT HAS TO SAY SO.
// idc 937410-937415 is a single set of controls, so a second concurrent prompt
// was never actually possible: it retitled the box under the first one and both
// then waited on ONE shared done/result pair, so a single OK press released
// both. The loser read a result that was already consumed, got nil, and
// returned null -- which this function's contract defines as "the player
// cancelled". A caller could not tell a refusal from a cancel from a stolen
// answer, and the page acted on a cancel that never happened.
//
// Refuse instead. A prompt that cannot have the overlay returns nil the same as
// a cancel does -- there is nowhere else for it to go through this API -- but it
// says so in the RPT rather than quietly corrupting the prompt that IS running.
if (uiNamespace getVariable ["WEBUI_promptBusy", false]) exitWith {
    diag_log format ["[PROMPT] refused '%1' -- another prompt already owns the overlay", _title];
    nil
};

// GENERATION STAMP. The busy flag stops two prompts overlapping; this stops a
// LATE one interfering. Button presses arrive as engine UI events and can land
// after the prompt they belong to has already given up (the dialog closed under
// it, say). Without a stamp that stale press satisfies whichever prompt is
// waiting next and hands it the wrong answer. A waiter accepts only a done
// signal carrying its own generation.
private _gen = (uiNamespace getVariable ["WEBUI_promptGen", 0]) + 1;
with uiNamespace do {
    WEBUI_promptGen    = _gen;
    WEBUI_promptBusy   = true;
    WEBUI_promptDone   = 0;
    WEBUI_promptResult = nil;
};

{ (_display displayCtrl _x) ctrlShow true; } forEach _ids;
ctrlSetFocus _edit;

// wait for OUR button press, or for the dialog to go away under us
waitUntil {
    (uiNamespace getVariable ["WEBUI_promptDone", 0]) isEqualTo _gen
    || { isNull (ctrlParent _webCtrl) }
};

{ (_display displayCtrl _x) ctrlShow false; } forEach _ids;

private _out = uiNamespace getVariable ["WEBUI_promptResult", nil];
with uiNamespace do {
    WEBUI_promptDone   = 0;
    WEBUI_promptResult = nil;
    WEBUI_promptBusy   = false;
};

if (isNil "_out") exitWith { nil };
if !(_out isEqualType "") exitWith { nil };

_out select [0, _max]
