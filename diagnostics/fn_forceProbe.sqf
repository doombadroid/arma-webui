// SPDX-License-Identifier: MIT
/*
    fn_forceProbe.sqf -- can ANYTHING make the engine repaint the browser faster?

    RETRACTED PREMISE -- read FINDINGS section 1 before this file.

    This probe was written believing "the engine draws this control ~1x/second
    and nothing the page does moves it". That is false for a normally launched
    game. Frame delivery is DIRTY-DRIVEN: an idle page sitting at ~0.6 fps is
    correct and desirable, and a 60Hz mutation drives it to ~60 fps. The ~1 fps
    ceiling is specific to a game launched OUTSIDE Steam, where the overlay hook
    that services this control is never injected.

    Every conclusion below that reads "nothing moved it" was measured on that
    clamped client and does not generalise. The probe is still useful -- it is
    the fullest sweep of engine-side levers available -- but treat its negative
    results as unproven until re-run on a Steam-launched client.

      1. baseline
      2. ctrlSetFocus on the browser control. document.hasFocus() read false
         when this was written -- ON THE CLAMPED CLIENT, like every number in
         this file. It is NOT evidence that input fails: typed text reaches
         the DOM normally (FINDINGS section 2, keyboard verified in game). How
         the control acquires keyboard focus is not recorded anywhere in this
         repo; what is established is that it does, and that hasFocus() is not
         a reliable witness. Here the lever is tried only for its possible
         effect on frame delivery.
      3. an EachFrame no-op ctrlCommit -- re-committing a control's own position
         is the cheapest way to mark it dirty every frame
      4. an EachFrame displayUpdate on the hosting display -- NOT APPLICABLE
         here, and skipped rather than sampled. displayUpdate only drives a
         UI-on-texture render; a browser control hosted the way this library
         documents (a dialog's class controls, or an RscTitles overlay) has an
         ordinary parent display, so the pump issues a draw request against
         nothing and the phase would report an idle baseline as a negative
         result. Re-run inside a ui2texture host if you need this lever
         measured. See FINDINGS section 1.
      5. ExecJS at ~30Hz from SQF -- if a repaint is coupled to receiving
         script rather than to running it, this is the one that would show it

    Arm first, then open a page:  [] spawn webui_fnc_forceProbe;
    ~35s. Results tagged [WEBUI-FORCE].
*/
if (!canSuspend) exitWith { diag_log "[WEBUI-FORCE] use spawn"; };

private _ctrl = [] call webui_fnc_awaitPage;
if (isNull _ctrl) exitWith {};
private _disp = ctrlParent _ctrl;



[_ctrl, "1 baseline", 5] call webui_fnc_countDraws;

// 2 -- focus
ctrlSetFocus _ctrl;
[_ctrl, "2 ctrlSetFocus on the ctrl", 5] call webui_fnc_countDraws;

// 3 -- mark the control dirty every frame
private _pos = ctrlPosition _ctrl;
private _mh = addMissionEventHandler ["EachFrame", {
    // EachFrame supplies no event data, so _this is empty here and the args
    // arrive in _thisArgs -- exactly as phase 4 below already reads them.
    // Reading them off _this left both variables undefined, so this handler
    // threw at its first statement every frame and the control was never
    // marked dirty: phase 3 sampled an untouched control and reported a
    // baseline as a negative result. FINDINGS section 1 listed
    // "EachFrame ctrlCommit" among the levers measured to do nothing on the
    // strength of this phase, which had never run.
    _thisArgs params ["_c", "_p"];
    _c ctrlSetPosition _p; _c ctrlCommit 0;
}, [_ctrl, _pos]];
[_ctrl, "3 EachFrame ctrlCommit", 5] call webui_fnc_countDraws;
removeMissionEventHandler ["EachFrame", _mh];

// 4 -- the documented UI-on-texture pump
// displayUpdate does exactly one thing: "Set the provided display to update its
// UI On Texture render" (BIKI). ctrlParent of a browser control hosted the way
// this library documents -- a dialog's class controls, or an RscTitles overlay
// -- is NOT a UI-on-texture display, so the pump issues a draw request against
// nothing and this phase resamples the same idle control phase 1 sampled. That
// baseline was then published in FINDINGS section 1 as a measured negative for
// the lever. Same false-negative class as phase 3's _this/_thisArgs bug.
//
// There is no UI-on-texture path anywhere in this repo, so rather than pretend,
// say the phase does not apply here.
private _isUiOnTexture = false;   // no ui2texture host exists in this library
if (!_isUiOnTexture) then {
    diag_log "[WEBUI-FORCE] 4 EachFrame displayUpdate: NOT APPLICABLE -- displayUpdate only drives a UI-on-texture display, and this control's parent is an ordinary dialog/RscTitles display. Sampling it would report an idle baseline as a negative result. Re-run inside a ui2texture host if you need this lever measured.";
} else {
    private _mh2 = addMissionEventHandler ["EachFrame", { displayUpdate (_thisArgs select 0); }, [_disp]];
    [_ctrl, "4 EachFrame displayUpdate", 5] call webui_fnc_countDraws;
    removeMissionEventHandler ["EachFrame", _mh2];
};

// 5 -- is a repaint coupled to RECEIVING script?
private _spam = [_ctrl] spawn {
    params ["_c"];
    private _end = diag_tickTime + 5.5;
    while { diag_tickTime < _end && { !isNull _c } } do {
        _c ctrlWebBrowserAction ["ExecJS", "window.__f=(window.__f||0)+1;"];
        uiSleep 0.033;
    };
};
[_ctrl, "5 ExecJS ~30Hz from SQF", 5] call webui_fnc_countDraws;
terminate _spam;

diag_log "[WEBUI-FORCE] done";
