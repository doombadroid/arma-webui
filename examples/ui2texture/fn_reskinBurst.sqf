/*
    fn_reskinBurst.sqf  (webui_fnc_reskinBurst) -- PROOF OF CONCEPT, 2026-09-06.
    Reskin a car with a two-second burst of TV static in between: the car "loses signal", then
    comes back wearing the new skin.

        [_veh, "random"] call webui_fnc_reskinBurst;    // a random stock livery that is NOT the one worn now
        [_veh, "black"]  call webui_fnc_reskinBurst;    // a textureSources class name of _veh's config
        [_veh, 2]        call webui_fnc_reskinBurst;    // or its index
        [_veh, "random", true] call webui_fnc_reskinBurst;   // debug: ignore the Chameleon Paint gate

    GATED ON THE MOD (2026-09-06): the car must have Chameleon Paint fitted -- vehicle mods slot 6,
    $15,000 in the vehicle shop's configure grid or the garage mod bay, published on the car as
    webui_chameleon. That is what makes this an upgrade rather than a free button.

    Called from your UI (a button, a radial, a scroll action). The list the
    ring shows is the vehicle's own configFile >> CfgVehicles >> <class> >> textureSources -- the
    stock Arma liveries, which is the proof of concept the owner asked for. No money, no
    persistence, no DB: this does not touch the skin shop (whatever persists liveries in your mission) at all.

    THE STATIC is static.html rendered through UI-on-texture (display webui_uiTexStatic) onto
    every hidden selection with setObjectTextureGlobal (2026-09-06: "broadcast the static") --
    the STRING goes to every client, each of which builds its own display and browser. What the
    string cannot carry is the pump, so fn_staticPump is remoteExec'd to every player within
    webui_skinStaticRange (500 m) to displayUpdate it for webui_skinStaticSecs (2.0) and close it. One
    browser per viewer per car for two seconds; players further away just see the skin change.

    THE SKIN lands through BIS_fnc_initVehicle with the textureSources class name: it is the engine's
    own customisation path, effect GLOBAL (it uses setObjectTextureGlobal inside), and it takes the
    texture list in the config's own selection order, so a source with two or three textures paints
    every selection right. Because it is global it also overwrites the local static on this client,
    which is exactly the hand-over wanted. Argument must be local: the driver's client owns the car.

    Busy-latched per vehicle (webui_skinBusy) so a second click during the static is ignored rather
    than stacking two timers on one car.
*/
params [["_veh", objNull, [objNull]], ["_skin", "", ["", 0]], ["_force", false, [false]]];
if (!hasInterface || {isNull _veh}) exitWith { false };
if (!_force && {!(_veh getVariable ["webui_chameleon", false])}) exitWith {
    systemChat "This car has no Chameleon Paint fitted -- it is a vehicle shop upgrade."; false
};
if (_veh getVariable ["webui_skinBusy", false]) exitWith { false };

private _src = configFile >> "CfgVehicles" >> (typeOf _veh) >> "textureSources";
private _classes = "true" configClasses _src;
if (_classes isEqualTo []) exitWith {
    systemChat "This vehicle has no stock skins to switch between."; false
};
private _cfg = if (_skin isEqualType 0) then { _classes param [_skin, configNull] } else {
    if (_skin isEqualTo "random") then {
        // any source whose FIRST texture is not what the car wears now -- so a click always changes something
        private _worn = toLower ((_veh getObjectTextures []) param [0, ""]);
        private _pool = _classes select { toLower ((getArray (_x >> "textures")) param [0, "?"]) isNotEqualTo _worn };
        if (_pool isEqualTo []) then { _pool = _classes; };
        selectRandom _pool
    } else { _src >> _skin }
};
if (isNull _cfg || {!isClass _cfg}) exitWith {
    diag_log format ["[WEBUI-SKIN] %1: no textureSource '%2' (have %3)", typeOf _veh, _skin, _classes apply { configName _x }]; false
};
private _id = configName _cfg;
private _n = count (_veh getObjectTextures []);
if (_n isEqualTo 0) exitWith { false };

_veh setVariable ["webui_skinBusy", true];
if (isNil "webui_uiTexStaticPreloaded") then {   // the ui2texture mipmap workaround, once per session
    private _tmp = (findDisplay 46) createDisplay "webui_uiTexStatic";
    _tmp closeDisplay 1;
    webui_uiTexStaticPreloaded = true;
};
private _name = toLower ("apstatic_" + ((netId _veh) regexReplace ["[^0-9A-Za-z]", "_"]));
private _tex = format ["#(rgb,512,512,1)uiEx(display:webui_uiTexStatic,uniqueName:%1,bgColor:#000000ff)", _name];
for "_i" from 0 to (_n - 1) do { _veh setObjectTextureGlobal [_i, _tex]; };
private _secs = missionNamespace getVariable ["webui_skinStaticSecs", 2.0];
private _near = allPlayers select { (_x distance _veh) < (missionNamespace getVariable ["webui_skinStaticRange", 500]) };
[_veh, _name, _secs] remoteExec ["webui_fnc_staticPump", _near];   // includes this client: one pump path, not two
diag_log format ["[WEBUI-SKIN] %1 -> '%2' (%3): static broadcast on %4 selection(s) to %5 viewer(s); asked %6 of %7", typeOf _veh, _id, getText (_cfg >> "displayName"), _n, count _near, _skin, _classes apply { configName _x }];

[_veh, _id, _name, _secs] spawn {
    params ["_veh", "_id", "_name", "_secs"];
    uiSleep _secs;   // the pump runs in fn_staticPump on every viewer, this client included
    // ARRAY form, not the bare name: BIS_fnc_initVehicle reads a String as a VARIANT class from
    // CfgVehicles / CfgVehicleTemplates, not as a textureSources entry. The first live run passed
    // "Red" as a string, got `true` back, and the paint never changed. ["Red", 1] is "this source,
    // probability 1" -- the documented way to name one textureSource.
    private _ok = if (alive _veh) then { [_veh, [_id, 1], false, false] call BIS_fnc_initVehicle } else { false };
    // BELT AND BRACES, LOCALLY: the static was a LOCAL setObjectTexture, and the landing is a GLOBAL
    // one. If the chosen skin is the one the car already wears, the global write may be a no-op on
    // this client (same value as before) and the static would never be overwritten. So the config's
    // own textures[] for the source are also written locally, index by index. Global and local now
    // agree by construction, whatever the engine decided to skip.
    if (_ok) then {
        private _texs = getArray (configFile >> "CfgVehicles" >> (typeOf _veh) >> "textureSources" >> _id >> "textures");
        { _veh setObjectTexture [_forEachIndex, _x]; } forEach _texs;
    };
    _veh setVariable ["webui_skinBusy", nil];
    diag_log format ["[WEBUI-SKIN] %1 -> '%2' landed=%3 after %4 s of static; textures now %5", typeOf _veh, _id, _ok, _secs, _veh getObjectTextures []];
    if (!_ok) then {   // never leave a car wearing dead air
        private _n = count (_veh getObjectTextures []);
        for "_i" from 0 to (_n - 1) do { _veh setObjectTexture [_i, "#reset"]; };
    };
};
true
