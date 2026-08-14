// SPDX-License-Identifier: MIT
/*
    fn_forceProbe.sqf -- can ANYTHING make the engine repaint the browser faster?

    Established: the engine draws this control ~1x/second, and nothing the PAGE
    does moves it (CSS off, rAF, and a 60Hz JS style mutation all measured the
    same). JS itself runs at full speed. So if there is a lever it is on the
    ENGINE side, not in the page. This tries every one available.

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
      4. an EachFrame displayUpdate on the hosting display -- this is the
         documented way to keep a UI-on-texture render flowing, and is the
         mechanism the BIKI's seamless Stop/Resume example uses
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
    params ["_c", "_p"];
    _c ctrlSetPosition _p; _c ctrlCommit 0;
}, [_ctrl, _pos]];
[_ctrl, "3 EachFrame ctrlCommit", 5] call webui_fnc_countDraws;
removeMissionEventHandler ["EachFrame", _mh];

// 4 -- the documented UI-on-texture pump
private _mh2 = addMissionEventHandler ["EachFrame", { displayUpdate (_thisArgs select 0); }, [_disp]];
[_ctrl, "4 EachFrame displayUpdate", 5] call webui_fnc_countDraws;
removeMissionEventHandler ["EachFrame", _mh2];

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
