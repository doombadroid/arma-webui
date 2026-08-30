// SPDX-License-Identifier: MIT
/*
    webui_fnc_prompt.sqf -- native text entry for web UI pages.

    Typed text reaches the DOM normally, so a real <input> in a page works and
    this is OPTIONAL. It exists for a native-looking prompt, and for when the
    browser is frozen.

    Shows an overlay in the SAME dialog as the browser -- a second dialog would
    fight over focus -- waits for OK/Cancel, and returns the string.

    Called from a page over the bridge:
        // The timeout is NOT optional here. WEBUI.call defaults to 10 s, and
        // this call waits on a HUMAN -- so without one the page's promise
        // rejects while the overlay is still on screen and the player is still
        // typing, and their eventual answer arrives with nobody waiting for it.
        const name = await WEBUI.call("promptText", ["Rename gang", current, 24], 60000);
        if (name !== null) { ... }          // null = cancelled

    Returns the entered string, or nil -- which has THREE causes: the player
    cancelled, the dialog closed under it, or this function refused (see below).

    NEEDS A SCHEDULED CONTEXT, and only one dispatcher gives it one. Through
    WEBUI.call, fn_init's CALL case spawns the handler and the waitUntil below
    is safe. Through WEBUI.ask it is NOT -- that case runs handlers inline and
    unscheduled, and both resolve names from the same webui_api map, so
    ask("promptText", ...) really does arrive here with no scheduler. The
    canSuspend guard at the top refuses it and the page receives false.

    DO NOT DELETE THAT GUARD AS REDUNDANT. An earlier version of this header
    asserted the context was always scheduled -- the exact belief the guard
    refutes. Without it the ASK path latches the busy flag, shows the overlay,
    then hits an unusable waitUntil: orphaned prompt, blocked browser, and a
    stranded session-lifetime latch.
*/

// _ctrl is OPTIONAL and appended last so existing callers keep working. It
// exists because resolving the display from the global WEBUI_ctrl -- the LAST
// control initialised -- routes the prompt to the wrong dialog as soon as more
// than one browser control is live, and FINDINGS 8 runs four. In that state a
// page calling promptText got the overlay of a different screen: if that screen
// lacked the overlay, fn_prompt returned nil, which this function's contract
// defines as "the player cancelled", so the page silently took the cancel
// branch without ever showing a prompt.
params [
    ["_title",   "Enter text", [""]],
    ["_prefill", "",           [""]],
    ["_max",     64,           [0]],
    ["_ctrl",    controlNull,  [controlNull]]
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
// This function waits, so it needs a scheduled context. It is reachable from the
// ASK dispatch, which runs handlers UNSCHEDULED inside the JSDialog handler: a
// page calling WEBUI.ask("promptText", ...) would reach the waitUntil below with
// no scheduler, after latching the busy flag and showing the overlay -- orphaning
// a visible prompt and leaving the browser blocked with no reply. Refuse before
// touching any state, exactly as webui_fnc_call does.
if (!canSuspend) exitWith {
    diag_log "[PROMPT] needs a scheduled context -- was this reached through WEBUI.ask? Use WEBUI.call, which is spawned.";
    nil
};

uiNamespace setVariable ["WEBUI_promptBusy", uiNamespace getVariable ["WEBUI_promptBusy", false]];

// CLEAR A STALE LATCH BEFORE THE GUARD READS IT. WEBUI_promptBusy lives in
// uiNamespace (GAME-session lifetime) but is only cleared by this function's
// tail, which runs in a mission-lifetime script. Kill that script mid-prompt --
// mission end, disconnect -- and the flag survives into the next mission set
// true, refusing every later prompt with nil, which this function's contract
// defines as "cancelled". So the latch records its owning display; a busy flag
// with no live owner cannot belong to a live prompt.
if (uiNamespace getVariable ["WEBUI_promptBusy", false]) then {
    private _owner = uiNamespace getVariable ["WEBUI_promptOwner", displayNull];
    if (isNull _owner) then {
        diag_log "[PROMPT] clearing a stale busy latch -- its owning display is gone (a prompt was almost certainly killed mid-wait by a mission end or a disconnect)";
        with uiNamespace do {
            WEBUI_promptBusy   = false;
            WEBUI_promptOwner  = displayNull;
            WEBUI_promptDone   = 0;
            WEBUI_promptResult = nil;
        };
    };
};
uiNamespace setVariable ["WEBUI_promptGen",  uiNamespace getVariable ["WEBUI_promptGen",  0]];
// Prefer the control the caller named; fall back to the published global only
// when nobody said. webui_fnc_init's own promptText handler now passes the
// control the page actually called through.
private _webCtrl = _ctrl;
if (isNull _webCtrl) then {
    _webCtrl = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
};
if (isNull _webCtrl) exitWith { diag_log "[PROMPT] no web control registered"; nil };
private _display = ctrlParent _webCtrl;
if (isNull _display) exitWith { nil };

private _ids  = [937410, 937411, 937412, 937413, 937414, 937415];
private _edit = _display displayCtrl 937413;
if (isNull _edit) exitWith {
    diag_log "[PROMPT] overlay controls missing from the dialog";
    nil
};

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

// CLAIM THE LATCH IMMEDIATELY AFTER THE GUARD. It used to sit below the
// seeding, leaving six statements (three regexReplace, a parseText, two
// ctrlSet*) between the guard's read of WEBUI_promptBusy and this write of it.
// Scheduled scripts are preempted between statements, so two prompts could both
// pass the guard and the loser's title and prefill were replaced by the winner's.
// This does not make the check-and-set atomic -- SQF has no compare-and-swap --
// but it removes every suspension point between the two.
//
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
    WEBUI_promptOwner  = _display;      // so a stale latch can be detected above
    WEBUI_promptDone   = 0;
    WEBUI_promptResult = nil;
};

// seed the field and title. The title arrives from the PAGE, so it is escaped
// before it becomes structured-text markup: an unescaped "&" or "<" made
// parseText fail and the prompt opened with a blank title, and any caller
// could otherwise inject <img>/<a> markup into a native Arma dialog.
// & first, or the escapes introduced below get escaped again.
private _safeTitle = _title regexReplace ["&", "&amp;"];
_safeTitle = _safeTitle regexReplace ["<", "&lt;"];
_safeTitle = _safeTitle regexReplace [">", "&gt;"];
(_display displayCtrl 937412) ctrlSetStructuredText parseText format [
    "<t size='1' font='RobotoCondensed' color='#c9e21a'>%1</t>", _safeTitle
];
// forceUnicode 1 before every substring select: the substring form of select
// "operates with the ANSI charset" (BIKI, select), so _max -- documented and
// used by callers as a CHARACTER limit -- was silently a BYTE limit, and a cut
// could land inside a multi-byte UTF-8 sequence and produce mojibake. Mode 1
// sets the flag for the next supported command only. forceUnicode is 2.02, well
// under this library's 2.20 floor.
forceUnicode 1;
_edit ctrlSetText (_prefill select [0, _max]);

{ (_display displayCtrl _x) ctrlShow true; } forEach _ids;
ctrlSetFocus _edit;

// wait for OUR button press, or for the dialog to go away under us
waitUntil {
    (uiNamespace getVariable ["WEBUI_promptDone", 0]) isEqualTo _gen
    || { isNull (ctrlParent _webCtrl) }
};

{ (_display displayCtrl _x) ctrlShow false; } forEach _ids;

// Hand the keyboard back. ctrlSetFocus above moved Arma's focus onto the edit
// box; hiding a control does not release it, so without this the focus stayed
// on a hidden CT_EDIT and every later keystroke aimed at the page's own
// <input> went nowhere. FINDINGS section 2 explicitly endorses real <input>,
// so a page that uses one prompt and then a text field looked broken with no
// error anywhere.
if (!isNull _webCtrl) then { ctrlSetFocus _webCtrl; };

private _out = uiNamespace getVariable ["WEBUI_promptResult", nil];

// RELEASE ONLY IF WE STILL HOLD THE LATCH. The staleness clear above makes the
// latch reclaimable mid-prompt, so this prompt can reach its tail after a newer
// one legitimately took it -- clearing unconditionally would strip a running
// prompt of its latch. The generation is the token, not the display: two
// sequential prompts in one dialog share a display.
if ((uiNamespace getVariable ["WEBUI_promptGen", 0]) isEqualTo _gen) then {
    with uiNamespace do {
        WEBUI_promptDone   = 0;
        WEBUI_promptResult = nil;
        WEBUI_promptBusy   = false;
        WEBUI_promptOwner  = displayNull;
    };
} else {
    diag_log format ["[PROMPT] not releasing the latch: generation %1 has taken it over from %2 -- leaving its state alone",
        uiNamespace getVariable ["WEBUI_promptGen", 0], _gen];
};

if (isNil "_out") exitWith { nil };
if !(_out isEqualType "") exitWith { nil };

forceUnicode 1;
_out select [0, _max]
