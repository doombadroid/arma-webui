/*
    fn_uiTexDemo.sqf -- paint an animated HTML page onto every hidden selection of a vehicle
    through the engine's UI-on-texture procedural texture. The probe behind FINDINGS section 12.

        [] call webui_fnc_uiTexDemo;          // vehicle under the cursor, else nearest car within 15 m
        [_veh] call webui_fnc_uiTexDemo;      // a specific vehicle
        [_veh] call webui_fnc_uiTexDemo;      // AGAIN on the same vehicle = off, #reset the skins

    Register it under your own CfgFunctions tag or exec it from the debug console; it needs
    webui_uiTexDemo.hpp included and matrix.html reachable. Client only.

    THE CHAIN: CT_WEBBROWSER (matrix.html) -> display webui_uiTexDemo -> #(rgb,...)uiEx(...)
    -> setObjectTexture on each hiddenSelection -> the model. The page draws a frame counter
    bottom-left; climbing = the whole chain is live, stuck at "f 1" = the display rendered once
    and displayUpdate is not reaching it, black = the browser never painted inside the texture.

    LOCAL ONLY. setObjectTexture, not Global: a probe must not broadcast a string every other
    client would then render. Going global is a one-word change with a per-client cost.

    THE MIPMAP WORKAROUND is real: a display used by ui2texture must have been shown in normal
    UI once, or its images fail with "Cannot load mipmap" (feedback T171035 / T170766).
    createDisplay + closeDisplay 1, once per session.

    THE DISPLAY IS CREATED BY THE FIRST TEXTURE DRAW, NOT BY THIS SCRIPT. findDisplay by the
    unique name (lowercase) is null until the engine has needed the texture once. The
    EachFrame pump tolerates that and starts updating when it appears. Without displayUpdate
    the texture renders once and freezes.

    Measured result (Arma 2.22.154049, Steam launch, Hatchback, 1 selection): display appeared
    the same frame the string was applied; browser Draw #1 at +54 frames, #60 at +59,
    #600 at +540 -- one browser paint per game frame. Everything logs under [WEBUI-UITEX].
*/
params [["_veh", objNull, [objNull]]];
if (!hasInterface) exitWith {};

if (isNull _veh) then {
    _veh = cursorObject;
    if (isNull _veh || {!(_veh isKindOf "LandVehicle")}) then {
        _veh = (nearestObjects [player, ["Car"], 15]) param [0, objNull];
    };
};
if (isNull _veh) exitWith { systemChat "uiTexDemo: no car under the cursor or within 15 m."; };

// ---- second call on the same vehicle: stop the pump and put the paint back ----
private _eh = _veh getVariable ["webui_uiTexEH", -1];
if (_eh > -1) exitWith {
    removeMissionEventHandler ["EachFrame", _eh];
    _veh setVariable ["webui_uiTexEH", nil];
    _veh setVariable ["webui_uiTexSeen", nil];
    private _n = count (_veh getObjectTextures []);
    for "_i" from 0 to (_n - 1) do { _veh setObjectTexture [_i, "#reset"]; };   // 2.20+
    private _d = findDisplay (_veh getVariable ["webui_uiTexName", ""]);
    if (!isNull _d) then { _d closeDisplay 1; };
    diag_log format ["[WEBUI-UITEX] OFF %1 -- %2 selection(s) reset, display still existed=%3", typeOf _veh, _n, !isNull _d];
    systemChat "uiTexDemo: off.";
};

// ---- can this object be textured at all? ----
private _defaults = _veh getObjectTextures [];
private _n = count _defaults;
diag_log format ["[WEBUI-UITEX] target %1 netId=%2 selections=%3 defaults=%4", typeOf _veh, netId _veh, _n, _defaults];
if (_n isEqualTo 0) exitWith { systemChat "uiTexDemo: that object has no hidden selections -- nothing to paint on."; };

// ---- mipmap workaround: show the display once in normal UI, then drop it ----
if (isNil "webui_uiTexPreloaded") then {
    private _tmp = (findDisplay 46) createDisplay "webui_uiTexDemo";
    diag_log format ["[WEBUI-UITEX] preload display=%1", _tmp];
    _tmp closeDisplay 1;
    webui_uiTexPreloaded = true;
};

// ---- the texture string. uniqueName must be [a-zA-Z0-9_]; netId is "n:m". ----
private _name = toLower ("demo_" + ((netId _veh) regexReplace ["[^0-9A-Za-z]", "_"]));
private _tex = format ["#(rgb,1024,1024,1)uiEx(display:webui_uiTexDemo,uniqueName:%1,bgColor:#000000ff)", _name];
_veh setVariable ["webui_uiTexName", _name];
for "_i" from 0 to (_n - 1) do { _veh setObjectTexture [_i, _tex]; };
diag_log format ["[WEBUI-UITEX] applied %1 to %2 selection(s): %3", _name, _n, _tex];

// ---- the pump: tell the display to re-render every frame, once it exists ----
_eh = addMissionEventHandler ["EachFrame", {
    _thisArgs params ["_veh", "_name"];
    if (isNull _veh) exitWith { removeMissionEventHandler ["EachFrame", _thisEventHandler]; };
    private _d = findDisplay _name;
    if (isNull _d) exitWith {};
    if !(_veh getVariable ["webui_uiTexSeen", false]) then {
        _veh setVariable ["webui_uiTexSeen", true];
        diag_log format ["[WEBUI-UITEX] display %1 appeared at frame %2 (ctrls=%3)", _name, diag_frameNo, count (allControls _d)];
        // "Draw" fires when Chromium painted a frame. If this never logs, the display exists
        // but the browser inside it is not rendering (check the launch path, FINDINGS section 1).
        private _ctrl = _d displayCtrl 941901;
        if (!isNull _ctrl) then {
            _ctrl ctrlAddEventHandler ["Draw", {
                private _c = ((_this select 0) getVariable ["webui_draws", 0]) + 1;
                (_this select 0) setVariable ["webui_draws", _c];
                if (_c in [1, 60, 600]) then { diag_log format ["[WEBUI-UITEX] browser Draw #%1 at frame %2", _c, diag_frameNo]; };
            }];
        };
    };
    displayUpdate _d;
}, [_veh, _name]];
_veh setVariable ["webui_uiTexEH", _eh];
systemChat "uiTexDemo: on. Look at the vehicle; the counter bottom-left of each panel should climb.";
