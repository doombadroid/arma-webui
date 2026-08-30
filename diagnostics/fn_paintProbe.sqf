// SPDX-License-Identifier: MIT
/*
    fn_paintProbe.sqf -- WHO is throttling the paint: dirty-tracking, the
    animation scheduler, or the Steam HTML surface?

    The page's own user agent says "Valve Steam Client": under Proton this
    browser is serviced by Steam's webhelper through the Steam HTML-surface
    API, not by a CEF inside Arma. That still stands, and so does the absence of
    CEF child processes.

    What does NOT stand is the sentence this used to end on -- "why paint sits at
    ~1 fps and why every engine-side lever did nothing". FINDINGS section 1
    retracted it: paint sits at ~1 fps only when the game was launched OUTSIDE
    Steam, because the overlay hook that services the surface is never injected.
    Launched through Steam the same page animates at ~60 fps. Read section 1
    before drawing any conclusion from this probe's numbers.

    Three samples counting the control's Draw events -- 5s, 5s and 6s (the
    overlay phase is longer because it waits on a human):
      1. baseline
      2. an animated GIF on screen -- Chromium animates GIFs with its own
         internal controller (no CSS, no rAF, no JS timers). Draw jumping here
         means frame delivery is dirty-driven and only the animation
         schedulers are suppressed. Draw staying ~1/s means BeginFrame itself
         is clamped upstream.
      3. the STEAM OVERLAY OPEN (you press SHIFT+TAB when told) -- if Steam is
         throttling the surface as "background", foregrounding Steam's own UI
         is the most direct way to change that state from the outside.

    Arm first, then open a page:  [] spawn webui_fnc_paintProbe;
*/
if (!canSuspend) exitWith { diag_log "[WEBUI-PAINT] use spawn"; };

private _ctrl = [] call webui_fnc_awaitPage;
if (isNull _ctrl) exitWith {};
private _disp = ctrlParent _ctrl;


systemChat "paint probe: baseline 5s -- hands off";
[_ctrl, "1 baseline", 5] call webui_fnc_countDraws;

// gifLoad and rafRate must be registered BY THE PAGE (WEBUI.handle), and no
// page in this repo registers either -- so the return value used to be
// discarded, the call timed out silently, and this phase sampled an IDLE page
// and reported ~0.6 fps. Per this file's header that reads as "BeginFrame is
// clamped upstream", which is how FINDINGS 1's animated-GIF column was produced.
// SKIP PHASE 2 ONLY -- NEVER THE WHOLE PROBE. The GIF phase needs a page-side
// gifLoad handler and no page here has one, so aborting ends the script before
// the Steam-overlay phase, which needs nothing from the page and is the
// decisive lever.
private _gifOn = [_ctrl, "gifLoad", [true], 6] call webui_fnc_call;
if (isNil "_gifOn" || { _gifOn isEqualTo false }) then {
    diag_log "[WEBUI-PAINT] SKIPPING PHASE 2: no acknowledgement from the page's 'gifLoad' handler.";
    diag_log "[WEBUI-PAINT]   To measure the GIF phase the page must implement, and RETURN TRUE from:";
    diag_log "[WEBUI-PAINT]     WEBUI.handle('gifLoad', function (on) { /* show/hide the GIF */ return true; });";
    diag_log "[WEBUI-PAINT]     WEBUI.handle('rafRate', function () { /* measured rAF fps */ return n; });";
    diag_log "[WEBUI-PAINT]   A handler that acts but returns nothing reads the same as no handler, which is why the acknowledgement is required.";
    diag_log "[WEBUI-PAINT]   Continuing to the Steam-overlay phase, which needs nothing from the page.";
    systemChat "paint probe: GIF phase skipped (page has no gifLoad) -- continuing";
} else {
    systemChat "paint probe: GIF phase -- a flashing square should be bottom-right of the phone";
    [_ctrl, "2 animated GIF (20fps)", 5] call webui_fnc_countDraws;
    // Formatting a nil in a scheduled context RAISES (BIKI, nil) -- this line used
    // to abort the probe before its cleanup and its Steam-overlay phase ever ran.
    private _raf = [_ctrl, "rafRate", [], 8] call webui_fnc_call;
    if (isNil "_raf") then { _raf = "no 'rafRate' handler on this page"; };
    diag_log format ["[WEBUI-PAINT]   rAF during GIF: %1 fps", _raf];
    [_ctrl, "gifLoad", [false], 6] call webui_fnc_call;
};

diag_log "[WEBUI-PAINT] >>> OPEN THE STEAM OVERLAY NOW (SHIFT+TAB) and leave it open <<<";
// The RPT is invisible in game -- cue on screen and with a horn instead.
playSound "Alarm";   // a class playSound's own BIKI page demonstrates; this library ships no CfgSounds of its own
titleText ["<t size='1.4' color='#c9e21a'>OPEN THE STEAM OVERLAY NOW (SHIFT+TAB)<br/>leave it open until the next message</t>", "PLAIN", 0.2, true, true];
systemChat ">>> OPEN THE STEAM OVERLAY NOW (SHIFT+TAB) and LEAVE IT OPEN <<<";
uiSleep 3;
// Sample the GAME's frame rate around this phase too. The probe cannot see
// whether the operator actually opened the overlay, and a phase labelled
// "steam overlay open" that was taken with it closed is a mislabelled duplicate
// of the baseline. A markedly changed game frame rate is the only evidence
// available from inside that the state changed at all.
private _fpsBeforeOverlay = diag_fps;
private _drawsOverlay = [_ctrl, "3 steam overlay open", 6] call webui_fnc_countDraws;
private _fpsDuringOverlay = diag_fps;
if (_drawsOverlay < 0) then {
    diag_log "[WEBUI-PAINT]   phase 3: NO SAMPLE (refused, or the control went away) -- this is not a rate; rerun";
} else {
    diag_log format ["[WEBUI-PAINT]   phase 3: draws=%1 fps, game fps %2 -> %3%4",
        _drawsOverlay toFixed 1, _fpsBeforeOverlay toFixed 1, _fpsDuringOverlay toFixed 1,
        if (abs (_fpsDuringOverlay - _fpsBeforeOverlay) < 2) then
            { "  <-- game fps barely moved; NO EVIDENCE the overlay was actually opened, treat this phase as unlabelled" }
        else { "" }];
};
playSound "Alarm";   // a class playSound's own BIKI page demonstrates; this library ships no CfgSounds of its own
titleText ["<t size='1.2' color='#33ffbb'>done -- close the overlay</t>", "PLAIN", 0.2, true, true];
systemChat "PAINT PROBE DONE -- close the overlay";
diag_log "[WEBUI-PAINT] close the overlay. done";

