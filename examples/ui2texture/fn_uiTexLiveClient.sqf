/*
    fn_uiTexLiveClient.sqf  (webui_fnc_uiTexLiveClient) -- the per-viewer half of a LIVE (animated) HTML
    texture on any object. remoteExec'd, JIP-queued, by whoever applied the texture string:

        [_obj, "apmatrix_u_<uid>"] remoteExec ...    (CfgRemoteExec: allowedTargets = 1, jip = 1)

    A static HTML skin (fn_htmlSkinClient) paints once and freezes. An animated one has to be pumped
    with displayUpdate every frame on EVERY viewer, and the string that replicates cannot carry a
    pump -- so each viewer registers [object, displayName] with webui_fnc_uiTexManager, which sorts every
    live surface by distance from the camera each frame and pumps only the nearest webui_uiTexCap (20),
    stopping the browsers beyond it. The display itself appears on this client the first time the
    engine draws the texture; the manager tolerates a display that is not there yet.
    An empty name unregisters (the applier sends that on "off").
*/
params [["_obj", objNull, [objNull]], ["_name", "", [""]], ["_on", true, [true]]];
if (!hasInterface || {isNull _obj}) exitWith {};
if (_name isEqualTo "") exitWith {};
if (_on) then {
    if (isNil "webui_uiTexDemoPreloaded") then {   // mipmap workaround, once per session, for the display class in use
        private _tmp = (findDisplay 46) createDisplay "webui_uiTexDemo";
        _tmp closeDisplay 1;
        webui_uiTexDemoPreloaded = true;
    };
    [_obj, _name] call webui_fnc_uiTexManager;
    diag_log format ["[WEBUI-UITEX] live texture %1 on %2 registered with the manager", _name, _obj];
} else {
    [_obj, _name, false] call webui_fnc_uiTexManager;
    private _d = findDisplay _name; if (!isNull _d) then { _d closeDisplay 1; };
};
