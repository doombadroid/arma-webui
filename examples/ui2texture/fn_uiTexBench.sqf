/*
    fn_uiTexBench.sqf  (webui_fnc_uiTexBench) -- what do N live HTML textures cost this client?

        [] call webui_fnc_uiTexBench;              // 10 cars, 10 s
        [20, 15] call webui_fnc_uiTexBench;        // 20 cars, 15 s
        [10, 10, "C_Offroad_01_F"] call webui_fnc_uiTexBench;

    Samples diag_fps for 3 s as a baseline, spawns N LOCAL cars in a row in front of the player
    (createVehicleLocal: nothing crosses the network), paints every one with the static page through
    UI-on-texture (its own display + browser each, exactly what N HTML-skinned cars would cost), pumps
    all N displays every frame for the run, samples diag_fps over the last part of it, then deletes
    everything and closes every display. Result to chat and the RPT as [WEBUI-UITEX] uiTexBench.

    The number that matters is the delta at N. The JS is not the suspect (canvas noise at 256 px is
    nothing); the readback is -- every displayUpdate copies a browser frame into a GPU texture -- and
    CEF memory per instance, which this cannot read. Stand still, look at the row, and do not open a
    menu while it runs: a dialog changes what the engine draws.
*/
params [["_n", 10, [0]], ["_secs", 10, [0]], ["_class", "C_Hatchback_01_F", [""]], ["_keepCap", false, [false]]];
if (!hasInterface) exitWith {};
if (!isNil "webui_uiTexBenchRunning") exitWith { systemChat "uiTexBench: already running"; };
webui_uiTexBenchRunning = true;

[_n, _secs, _class, _keepCap] spawn {
    params ["_n", "_secs", "_class", "_keepCap"];
    private _fnSample = { params ["_for"]; private _a = []; private _t = diag_tickTime + _for;
        while { diag_tickTime < _t } do { _a pushBack diag_fps; uiSleep 0.25; };
        if (_a isEqualTo []) then { 0 } else { ((_a call BIS_fnc_arithmeticMean) * 10) / 10 } };
    systemChat format ["uiTexBench: baseline 3 s, then %1 x %2 for %3 s -- stand still", _n, _class, _secs];
    private _base = [3] call _fnSample;

    if (isNil "webui_uiTexStaticPreloaded") then {
        private _tmp = (findDisplay 46) createDisplay "webui_uiTexStatic"; _tmp closeDisplay 1; webui_uiTexStaticPreloaded = true;
    };
    private _cars = []; private _names = [];
    private _dir = getDir player;
    // SIMPLE objects on a real grid (owner, first run: "several cars exploded which causes frame drops" --
    // createVehicleLocal in a tight fan put physics cars inside each other). createSimpleObject [class]
    // is Syntax 2: texturable, no PhysX, cannot collide or explode -- and it is the honest object kind,
    // because the only thing under test is the texture readback. 6 m across, 7 m between rows.
    for "_i" from 0 to (_n - 1) do {
        private _col = _i mod 5; private _row = floor (_i / 5);
        private _p = player getPos [15 + 7 * _row, _dir];
        _p = _p getPos [6 * (_col - 2), _dir + 90];
        private _c = createSimpleObject [_class, AGLToASL _p vectorAdd [0, 0, 0.9], true];
        _c setDir (_dir + 180);
        private _name = format ["apbench_%1", _i];
        private _tex = format ["#(rgb,512,512,1)uiEx(display:webui_uiTexStatic,uniqueName:%1,bgColor:#000000ff)", _name];
        private _k = count (_c getObjectTextures []);
        for "_j" from 0 to (_k - 1) do { _c setObjectTexture [_j, _tex]; };
        _cars pushBack _c; _names pushBack _name;
    };
    // through the manager, with the cap lifted to N for the run: the bench measures the raw per-surface
    // cost, the cap is what production runs under. `[10, 10, "C_Hatchback_01_F", true]` keeps the cap on.
    private _capWas = missionNamespace getVariable ["webui_uiTexCap", 20];
    if (!_keepCap) then { webui_uiTexCap = _n; };
    { [_cars select _forEachIndex, _x] call webui_fnc_uiTexManager; } forEach _names;
    uiSleep 2;   // let the browsers boot
    private _live = { !isNull (findDisplay _x) } count _names;
    private _loaded = [(_secs - 2) max 2] call _fnSample;
    { [_cars select _forEachIndex, _x, false] call webui_fnc_uiTexManager; } forEach _names;
    webui_uiTexCap = _capWas;
    { deleteVehicle _x } forEach _cars;   // simple objects delete cleanly; nothing burns
    { private _d = findDisplay _x; if (!isNull _d) then { _d closeDisplay 1; }; } forEach _names;
    uiSleep 1;
    private _after = [3] call _fnSample;
    private _msg = format ["uiTexBench %1 x %2: baseline %3 fps -> loaded %4 fps (%5 displays live, cap %6) -> after cleanup %7 fps",
        _n, _class, _base, _loaded, _live, if (_keepCap) then { _capWas } else { "off" }, _after];
    diag_log format ["[WEBUI-UITEX] %1", _msg];
    systemChat _msg;
    webui_uiTexBenchRunning = nil;
};
