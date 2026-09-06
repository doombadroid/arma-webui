/*
    fn_uiTexManager.sqf  (webui_fnc_uiTexManager) -- ONE pump for every live HTML texture on this client,
    capped to the nearest webui_uiTexCap (20) objects. 2026-09-06: "cap live html surfaces to nearest
    20 cars" -- the bench showed ~0.3 ms of frame time per pumped surface and a hard 30 fps floor past
    about sixty, so the budget is a count, not a distance.

        [_obj, "apstatic_<netid>"] call webui_fnc_uiTexManager;          // register: pump this display for this object
        [_obj, "apstatic_<netid>", false] call webui_fnc_uiTexManager;   // unregister (the caller closes the display)
        webui_uiTexCap = 20;                                              // live at any time

    HOW IT CAPS. Every frame the registry is pruned of null objects and displays, sorted by distance
    from the CAMERA (not the player -- a spectator or a PiP shot sees what the camera sees), and only
    the first webui_uiTexCap get displayUpdate. A ui2texture display that is not updated is frozen on its
    last frame at zero readback cost -- but its Chromium keeps painting in its own process, so a
    surface that drops out of the top N also gets "StopBrowser" on its control, and "ResumeBrowser"
    when it climbs back in (the page reloads; for a noise or animation page that is invisible). That
    is what makes the cap a cost cap rather than a readback cap.

    Callers: fn_staticPump (the 2 s reskin static, every viewer), fn_uiTexMatrix, fn_uiTexHolo,
    fn_uiTexBench (which raises the cap to N for the run, so it still measures the raw cost).
*/
params [["_obj", objNull, [objNull]], ["_name", "", [""]], ["_on", true, [true]]];
if (!hasInterface) exitWith {};
if (isNil "webui_uiTexReg") then { webui_uiTexReg = []; };
if (isNil "webui_uiTexCap") then { webui_uiTexCap = 20; };

if (_name isNotEqualTo "") then {
    private _i = webui_uiTexReg findIf { (_x select 1) isEqualTo _name };
    if (_on) then {
        if (_i isEqualTo -1) then { webui_uiTexReg pushBack [_obj, _name, true]; };
    } else {
        if (_i > -1) then { webui_uiTexReg deleteAt _i; };
    };
};

if (isNil "webui_uiTexManagerEH") then {
    webui_uiTexManagerEH = addMissionEventHandler ["EachFrame", {
        if (webui_uiTexReg isEqualTo []) exitWith {};
        private _cam = positionCameraToWorld [0, 0, 0];
        // prune on a null OBJECT only. The display is created by the engine's FIRST DRAW of the texture,
        // which is a second or more after registration -- pruning on a null display  dropped
        // every entry before it could ever be pumped, and every live surface froze on a black first frame.
        webui_uiTexReg = webui_uiTexReg select { !isNull (_x select 0) };
        private _sorted = [webui_uiTexReg, [], { (_x select 0) distance _cam }, "ASCEND"] call BIS_fnc_sortBy;
        {
            _x params ["_o", "_n", "_live"];
            private _d = findDisplay _n;
            if (isNull _d) then { continue };   // not drawn yet; pump it the frame it exists
            if (_forEachIndex < webui_uiTexCap) then {
                if (!_live) then {
                    private _c = (allControls _d) param [0, controlNull];
                    if (!isNull _c) then { _c ctrlWebBrowserAction ["ResumeBrowser"]; };
                    _x set [2, true];
                };
                displayUpdate _d;
            } else {
                if (_live) then {
                    private _c = (allControls _d) param [0, controlNull];
                    if (!isNull _c) then { _c ctrlWebBrowserAction ["StopBrowser"]; };
                    _x set [2, false];
                };
            };
        } forEach _sorted;
        webui_uiTexReg = _sorted;
    }];
};
