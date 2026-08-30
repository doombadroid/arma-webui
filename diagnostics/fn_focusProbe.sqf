// SPDX-License-Identifier: MIT
/*
    fn_focusProbe.sqf -- does WINDOW FOCUS feed the browser's frame clamp?

    The Steam overlay will not draw on this client (hook and Vulkan layer are
    both correctly injected -- it is the overlay UI that fails, likely the
    webhelper-rendered overlay under GE-Proton), so the overlay cannot be used
    as the lever on Steam's surface state. Focus can: alt-tabbing the game away
    and back is the strongest focus transition available from outside.

      1. baseline, focused          (5s)
      2. ALT-TABBED AWAY            (6s)  -- horn tells you when
      3. back, refocused            (6s)  -- horn again

    If draws jump in 2 or 3, surface state responds to focus and the clamp is
    negotiable. If all three read ~1 fps, focus is not the lever either.

    Arm first, then open a page:  [] spawn webui_fnc_focusProbe;
*/
if (!canSuspend) exitWith { diag_log "[WEBUI-FOCUS] use spawn"; };

private _ctrl = [] call webui_fnc_awaitPage;
if (isNull _ctrl) exitWith {};
private _disp = ctrlParent _ctrl;


// Sample the GAME's frame rate alongside the control's Draw count in every
// phase. Draw is an Arma control event, so while the window is unfocused Arma
// may stop rendering entirely -- and then phase 2 reading ~0 says nothing about
// browser frame delivery, which is the only thing this probe claims to test.
// Without this, "all three read ~1 fps, so focus is not the lever" was a
// conclusion about the browser drawn from a measurement that may be about the
// game window.
private _phase = {
    params ["_c", "_label", "_secs"];
    private _gameBefore = diag_fps;
    private _draws = [_c, _label, _secs] call webui_fnc_countDraws;
    private _gameAfter = diag_fps;
    private _gameMean = (_gameBefore + _gameAfter) / 2;
    if (_draws < 0) then {
        // countDraws returns -1 for a refusal (another sample already running --
        // the automatic clamp check does exactly that) or a control that died
        // mid-window. Printing it as "draws=-1.0 fps" presents a non-sample as a
        // measurement.
        diag_log format ["[WEBUI-FOCUS] %1: NO SAMPLE (refused, or the control went away) -- this is not a rate; rerun", _label];
    } else {
        diag_log format ["[WEBUI-FOCUS] %1: draws=%2 fps, game=%3 fps%4",
            _label, _draws toFixed 1, _gameMean toFixed 1,
            if (_gameMean < 5) then { "  <-- GAME was barely rendering; this sample is UNINTERPRETABLE for browser delivery" } else { "" }];
    };
    [_draws, _gameMean]
};

systemChat "focus probe: baseline 5s -- hands off";
[_ctrl, "1 focused baseline", 5] call _phase;

playSound "Alarm";   // a class playSound's own BIKI page demonstrates; this library ships no CfgSounds of its own
titleText ["<t size='1.4' color='#c9e21a'>ALT-TAB AWAY FROM THE GAME NOW<br/>stay away until the next horn</t>", "PLAIN", 0.2, true, true];
systemChat ">>> ALT-TAB AWAY NOW -- stay away until the horn <<<";
uiSleep 2;
[_ctrl, "2 alt-tabbed away", 6] call _phase;

playSound "Alarm";   // a class playSound's own BIKI page demonstrates; this library ships no CfgSounds of its own
systemChat ">>> COME BACK to the game now <<<";
uiSleep 2;
[_ctrl, "3 back, refocused", 6] call _phase;

playSound "Alarm";   // a class playSound's own BIKI page demonstrates; this library ships no CfgSounds of its own
titleText ["<t size='1.2' color='#33ffbb'>focus probe done</t>", "PLAIN", 0.2, true, true];
systemChat "FOCUS PROBE DONE";
diag_log "[WEBUI-FOCUS] done";
