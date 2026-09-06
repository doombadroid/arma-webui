/*
    fn_htmlSkin.sqf  (webui_fnc_htmlSkin) -- SPIKE, 2026-09-06: a vehicle skin that lives on the
    SERVER as an HTML page and is streamed to whoever looks at the car. No PBO, no mod, no client file.

        [_veh, "hatch_red"] call webui_fnc_htmlSkin;     // ids = <server page root>/skins/<id>.html
        [_veh, "off"] call webui_fnc_htmlSkin;           // #reset, and tell everyone to forget it

    THE CHAIN. The car's hidden selections get, via setObjectTextureGlobal, the string
        #(rgb,512,512,1)uiEx(display:webui_uiTexSkin,uniqueName:apskin_<id>)
    which replicates to every client (JIP-safe: the engine keeps object textures). On each client the
    engine creates display "apskin_<id>" the first time it draws that texture; webui_fnc_htmlSkinClient
    (remoteExec'd here to everyone, JIP-queued) watches for it, initialises the webui bridge on the
    browser inside it, and asks the server for skins\<id>.html through the ordinary
    webui_fnc_serve path -- sha1-tagged, cached per session, "unchanged" when already held. The page
    is a JPEG data URI stretched over the document. After the browser's first Draw the display is
    never pumped again (a static skin is one paint) and the browser is stopped: per-frame cost zero.

    ONE DISPLAY PER SKIN, NOT PER CAR. The unique name is the skin id, so ten cars in hatch_red share
    one display and one browser on every viewer. Distinct skins in view, not cars, is the count the
    uiTex cap applies to.

    WHAT THE SPIKE IS FOR: does a frozen ui2texture survive ten idle minutes, alt-tab, VRAM pressure --
    or come back black? fn_htmlSkinClient logs every 60 s whether each served display still exists.
    The paint itself is the owner's eyeball.
*/
params [["_veh", objNull, [objNull]], ["_id", "", [""]]];
if (!hasInterface || {isNull _veh}) exitWith { false };
private _n = count (_veh getObjectTextures []);
if (_n isEqualTo 0) exitWith { systemChat "That class has no hidden selections."; false };

if (_id in ["", "off"]) exitWith {
    for "_i" from 0 to (_n - 1) do { _veh setObjectTextureGlobal [_i, "#reset"]; };
    _veh setVariable ["webui_htmlSkin", nil, true];
    diag_log format ["[WEBUI-HSKIN] %1 reset", typeOf _veh];
    true
};
private _safe = toLower (_id regexReplace ["[^0-9A-Za-z_]", "_"]);
private _name = "apskin_" + _safe;
private _tex = format ["#(rgb,512,512,1)uiEx(display:webui_uiTexSkin,uniqueName:%1,bgColor:#000000ff)", _name];
for "_i" from 0 to (_n - 1) do { _veh setObjectTextureGlobal [_i, _tex]; };
_veh setVariable ["webui_htmlSkin", _safe, true];
// everyone, JIP-queued under one key per vehicle so a late joiner gets the latest skin only once
[_safe] remoteExec ["webui_fnc_htmlSkinClient", 0, format ["apskin_%1", netId _veh]];
diag_log format ["[WEBUI-HSKIN] %1 -> %2 on %3 selection(s); string broadcast, client service told", typeOf _veh, _safe, _n];
true
