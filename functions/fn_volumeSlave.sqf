// SPDX-License-Identifier: MIT
/*
    fn_webVolSlave.sqf -- make page audio obey Arma's volume sliders.

    The browser plays through the OS mixer, so none of Arma's volume sliders
    reach it: a muted player still hears the page. That alone makes page audio
    unshippable without this.

    THE FIX
      Arma's sliders cannot reach CEF, but SQF can READ them. musicVolume,
      soundVolume and radioVolume are ordinary commands. Push their values to
      the page and let the page multiply its own gain by them -- obedience by
      cooperation rather than by the audio stack.

      Distance rides along on the same channel, so a page can duck exactly the
      way the native radio ducks for bystanders (fn_radioListen does this in the
      extension DLL; in a page it is one multiply).

          effective gain = in-page slider  x  musicVolume  x  distance falloff

    Pushes only when something actually moves -- the values are compared before
    sending, so a still player costs one comparison per tick and no ExecJS.

    Usage:  [_ctrl] spawn webui_fnc_volumeSlave;
            [_ctrl, _emitterObj] spawn webui_fnc_volumeSlave;   // with falloff
*/

params [["_ctrl", controlNull, [controlNull]], ["_emitter", objNull, [objNull]], ["_range", 20, [0]]];
if (isNull _ctrl) exitWith { diag_log "[WEBUI-VOL] null control"; false };

// persisted in-page volume, names/numbers only -- never code (profileNamespace
// is client-writable; see security.md)
[_ctrl, "setVol", {
    params [["_v", 0.7, [0]]];
    private _clamped = (_v max 0) min 1;
    profileNamespace setVariable ["WEBUI_volume", _clamped];
    saveProfileNamespace;
    createHashMapFromArray [["ok", true], ["msg", format ["volume %1%2", round (_clamped * 100), "%"]]]
}] call webui_fnc_on;

// Esc closes any dialog, so Arma's own options menu cannot be opened while a
// browser page is up. This lets the page drive the game's music level instead,
// which is also a live end-to-end test of the slaving chain. fadeMusic is a
// runtime coefficient -- it does not touch the player's saved setting.
[_ctrl, "setArmaMusic", {
    params [["_v", 1, [0]]];
    private _clamped = (_v max 0) min 1;
    0 fadeMusic _clamped;
    createHashMapFromArray [["ok", true], ["msg", format ["music -> %1%2", round (_clamped * 100), "%"]]]
}] call webui_fnc_on;

// Send the persisted volume BEFORE the polling loop starts, so its first tick
// cannot land first and arrive without `saved`.
[_ctrl, "vol", createHashMapFromArray [
    ["music", musicVolume], ["sound", soundVolume], ["radio", radioVolume], ["dist", 1],
    ["saved", profileNamespace getVariable ["WEBUI_volume", 0.7]]
]] call webui_fnc_push;

[_ctrl, _emitter, _range] spawn {
    params ["_ctrl", "_emitter", "_range"];
    private _last = [-1, -1, -1];
    diag_log "[WEBUI-VOL] running -- move the in-game sliders and watch the page";

    while { !isNull _ctrl } do {
        private _mus = musicVolume;
        private _snd = soundVolume;

        // bystander falloff, mirroring the native radio's model: flat if you are
        // in the vehicle, linear to zero at _range otherwise
        private _dist = 1;
        if (!isNull _emitter) then {
            _dist = if ((vehicle player) isEqualTo _emitter) then { 1 } else {
                private _d = player distance _emitter;
                ((1 - (_d / _range)) max 0) min 1
            };
        };

        private _now = [_mus, _snd, _dist];
        // only speak when something changed -- a still player costs nothing
        if (!(_now isEqualTo _last)) then {
            _last = _now;
            [_ctrl, "vol", createHashMapFromArray [
                ["music", _mus], ["sound", _snd], ["radio", radioVolume], ["dist", _dist]
            ]] call webui_fnc_push;
        };
        uiSleep 0.25;
    };
    diag_log "[WEBUI-VOL] control gone, stopping";
};

true
