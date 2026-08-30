// SPDX-License-Identifier: MIT
/*
    fn_webVolSlave.sqf -- make page audio obey Arma's volume sliders.

    The browser plays through the OS mixer, so none of Arma's volume sliders
    reach it: a muted player still hears the page. That alone makes page audio
    unshippable without this.

    THE FIX
      Arma's sliders cannot reach CEF, but SQF can READ them. Push their values
      to the page and let the page multiply its own gain by them -- obedience by
      cooperation rather than by the audio stack.

      READ THE RIGHT COMMANDS. musicVolume, soundVolume and radioVolume are NOT
      the player's sliders: each returns the SCRIPTED fade coefficient set by
      fadeMusic/fadeSound/fadeRadio ("Returns the current music volume (set by
      fadeMusic)" -- BIKI), so they sit at 1 wherever the player drags the Audio
      Options sliders. An earlier version of this file read exactly those three
      and therefore never worked; nothing caught it because they return a
      perfectly plausible 1.0 and the page rendered fine.

      The player's sliders come from getAudioOptionVolumes (arma3 1.94), which
      returns [effects, music, radio, von, UI, map]. What the player actually
      hears is the product of the two -- fadeMusic's own page states it:
      "Final Volume = Client Setting * Scripted Volume" -- so the product is
      what this function pushes.

      Distance rides along on the same channel, so a page can duck exactly the
      way the native radio ducks for bystanders (fn_radioListen does this in the
      extension DLL; in a page it is one multiply).

          pushed music = (getAudioOptionVolumes music)  x  musicVolume
          effective gain = in-page slider  x  pushed music  x  distance falloff

    Pushes only when something actually moves -- the values are compared before
    sending, so a still player costs one comparison per tick and no ExecJS.

    Usage:  [_ctrl] spawn webui_fnc_volumeSlave;
            [_ctrl, _emitterObj] spawn webui_fnc_volumeSlave;   // with falloff
*/

params [["_ctrl", controlNull, [controlNull]], ["_emitter", objNull, [objNull]], ["_range", 20, [0]]];
if (isNull _ctrl) exitWith { diag_log "[WEBUI-VOL] null control"; false };

// persisted in-page volume, names/numbers only -- never code (profileNamespace
// is client-writable; see security.md)
// The obvious page wiring fires per slider step, so dragging rewrote the whole
// profile ~70 times a second. The BIKI warns saveProfileNamespace "triggers a
// file operation ... not recommended ... several times per second". Set the
// value now; persist once the slider stops.
[_ctrl, "setVol", {
    params [["_v", 0.7, [0]]];
    private _clamped = (_v max 0) min 1;
    profileNamespace setVariable ["WEBUI_volume", _clamped];

    missionNamespace setVariable ["webui_volSaveDue", diag_tickTime + 0.75];
    if !(missionNamespace getVariable ["webui_volSavePending", false]) then {
        missionNamespace setVariable ["webui_volSavePending", true];
        [] spawn {
            waitUntil {
                uiSleep 0.25;
                diag_tickTime > (missionNamespace getVariable ["webui_volSaveDue", 0])
            };
            // Clear the flag BEFORE the write. Clearing it after meant a setVol
            // landing during saveProfileNamespace saw pending=true, declined to
            // arm a writer, and was then never persisted by anyone -- the newest
            // value left in profileNamespace with no save behind it. Re-check
            // the deadline after the write so a value that arrived mid-write
            // still gets one.
            missionNamespace setVariable ["webui_volSavePending", false];
            saveProfileNamespace;
            if (diag_tickTime < (missionNamespace getVariable ["webui_volSaveDue", 0])) then {
                // something moved the slider while we were writing -- persist again
                missionNamespace setVariable ["webui_volSavePending", true];
                waitUntil {
                    uiSleep 0.25;
                    diag_tickTime > (missionNamespace getVariable ["webui_volSaveDue", 0])
                };
                missionNamespace setVariable ["webui_volSavePending", false];
                saveProfileNamespace;
            };
        };
    };

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
// Same product as the loop below: profile slider x scripted fade. Sending the
// bare scripted values here would have handed the page a different quantity
// from the one every later push carries.
getAudioOptionVolumes params [
    ["_seedFx", 1, [0]], ["_seedMusic", 1, [0]], ["_seedRadio", 1, [0]]
];
[_ctrl, "vol", createHashMapFromArray [
    ["music", _seedMusic * musicVolume],
    ["sound", _seedFx    * soundVolume],
    ["radio", _seedRadio * radioVolume],
    ["dist",  1],
    ["saved", profileNamespace getVariable ["WEBUI_volume", 0.7]]
]] call webui_fnc_push;

[_ctrl, _emitter, _range] spawn {
    params ["_ctrl", "_emitter", "_range"];
    private _last = [-1, -1, -1, -1];
    diag_log "[WEBUI-VOL] running -- move the in-game sliders and watch the page";

    while { !isNull _ctrl } do {
        // THE PLAYER'S SLIDERS ARE NOT musicVolume/soundVolume/radioVolume:
        // those return the SCRIPTED fade (BIKI), so they sit at 1 wherever the
        // sliders are, and a version of this that read them never worked. The
        // sliders come from getAudioOptionVolumes; what the player hears is the
        // product of the two ("Final Volume = Client Setting * Scripted Volume").
        getAudioOptionVolumes params [
            ["_optFx", 1, [0]], ["_optMusic", 1, [0]], ["_optRadio", 1, [0]]
        ];
        private _mus = _optMusic * musicVolume;
        private _snd = _optFx    * soundVolume;

        // bystander falloff, mirroring the native radio's model: flat if you are
        // in the vehicle, linear to zero at _range otherwise
        private _dist = 1;
        if (!isNull _emitter) then {
            _dist = if ((vehicle player) isEqualTo _emitter) then { 1 } else {
                private _d = player distance _emitter;
                ((1 - (_d / _range)) max 0) min 1
            };
        };

        // radioVolume BELONGS IN THE COMPARISON, not just the payload. It was
        // shipped every push and watched by none of them, so moving only the
        // Radio slider changed a value nobody was comparing: the guard below saw
        // no change, sent nothing, and the page kept a stale radio gain for the
        // rest of the session. Every field that goes out has to be a field that
        // can trigger a send.
        private _rad = _optRadio * radioVolume;
        private _now = [_mus, _snd, _rad, _dist];

        // Do not queue while the page cannot receive. webui_fnc_exec holds
        // statements until the bridge is up and caps the queue at 200; a frozen
        // browser sets webui_ready false with no signal coming to clear it (there
        // is no PageLoaded until Resume), so at 4 Hz this loop fills that queue in
        // under a minute and then logs "exec queue full, dropping" forever. On
        // resume all 200 stale volume pushes replay in order, every one of them
        // superseded by the last. Skipping while frozen costs nothing: the values
        // are re-read from scratch on the next tick, and the push right after
        // fn_freeze's resume carries the current state anyway.
        if (_ctrl getVariable ["webui_bridge", false]) then {
            // only speak when something changed -- a still player costs nothing
            if (!(_now isEqualTo _last)) then {
                _last = _now;
                // `saved` goes on EVERY push, not just the seed above. The
                // seed is sent once per volumeSlave call, but a page reload --
                // fn_freeze's resume, or any renavigation -- rebuilds the
                // page's channel map empty, and the loop's resend is then the
                // first `vol` message the new document ever sees. Without
                // `saved` a page seeding its user volume from v.saved got
                // undefined, gain became NaN, and the page went silent.
                [_ctrl, "vol", createHashMapFromArray [
                    ["music", _mus], ["sound", _snd], ["radio", _rad], ["dist", _dist],
                    ["saved", profileNamespace getVariable ["WEBUI_volume", 0.7]]
                ]] call webui_fnc_push;
            };
        } else {
            // Force a resend once the page comes back, whatever the sliders did
            // while it was down.
            _last = [-1, -1, -1, -1];
        };
        uiSleep 0.25;
    };
    diag_log "[WEBUI-VOL] control gone, stopping";
};

true
