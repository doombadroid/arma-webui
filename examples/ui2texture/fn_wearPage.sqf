/*
    fn_wearPage.sqf  (webui_fnc_wearPage) -- PROOF OF CONCEPT, 2026-09-06: Matrix rain as a
    CLOTHING skin. The uniform (and the backpack, if worn) wear the live HTML page matrix.html.

        [] call webui_fnc_wearPage;          // on yourself; again = off, textures #reset
        [_unit] call webui_fnc_wearPage;     // any unit (the caller must own it: setObjectTextureGlobal is AL)

    WHAT CLOTHING CAN TAKE IT, and this is the engine's rule not ours: a texture goes on a hidden
    selection, and on a person those are the UNIFORM (selection 0 -- what every clothing skin in the
    shop already targets through <your clothing-skin reapply hook>) and the BACKPACK (its own object, selection 0).
    Vests, headgear, goggles and NVGs have no hidden selection on the vanilla models and cannot be
    retextured by any command (BIKI setObjectTexture user note: "unfortunately does not work for
    vests"). So "any clothing" = uniforms and backpacks; the rest would need custom models.

    THE STRING IS GLOBAL AND JIP-SAFE; the PUMP IS PER VIEWER. setObjectTextureGlobal ships the
    uiEx(...) string; every client that draws the unit gets its own display + browser. Because this
    is animated, every viewer must pump it, so fn_uiTexLiveClient is remoteExec'd to all (JIP, one key
    per unit) and registers the surface with the cap manager -- nearest 20 live surfaces pumped,
    browsers beyond that stopped. The UV sheet of a uniform is a patchwork of islands, so the rain
    is cut into pieces across the body; it moves, which is the point of the probe.

    RESET RULES THE ENGINE IMPOSES: changing uniform, respawning, or opening the Arsenal resets a
    unit's custom texture (BIKI note). The clothing shop re-applies its skins on load via
    <your clothing-skin reapply hook> "setUniform"; a shipped version of this would hook the same place.
*/
params [["_unit", player, [objNull]]];
if (!hasInterface || {isNull _unit}) exitWith {};
private _name = toLower ("apmatrix_u_" + ((getPlayerUID _unit) regexReplace ["[^0-9A-Za-z]", "_"]));
private _bp = unitBackpack _unit;

if (_unit getVariable ["webui_wearPage", false]) exitWith {
    _unit setObjectTextureGlobal [0, "#reset"];
    if (!isNull _bp) then { _bp setObjectTextureGlobal [0, "#reset"]; };
    _unit setVariable ["webui_wearPage", nil, true];
    [_unit, _name, false] remoteExec ["webui_fnc_uiTexLiveClient", 0, format ["apmatrix_u_%1", netId _unit]];
    diag_log format ["[WEBUI-UITEX] wearMatrix OFF %1", name _unit];
    systemChat "Matrix off.";
};

private _tex = format ["#(rgb,512,512,1)uiEx(display:webui_uiTexDemo,uniqueName:%1,bgColor:#000000ff)", _name];
private _u = count (_unit getObjectTextures []);
if (_u isEqualTo 0) exitWith { systemChat "This uniform has no hidden selection -- nothing to paint on."; };
_unit setObjectTextureGlobal [0, _tex];
if (!isNull _bp && { count (_bp getObjectTextures []) > 0 }) then { _bp setObjectTextureGlobal [0, _tex]; };   // same display: one browser for both
_unit setVariable ["webui_wearPage", true, true];
[_unit, _name] remoteExec ["webui_fnc_uiTexLiveClient", 0, format ["apmatrix_u_%1", netId _unit]];
diag_log format ["[WEBUI-UITEX] wearMatrix ON %1: uniform %2 (%3 sel), backpack %4", name _unit, uniform _unit, _u, if (isNull _bp) then { "none" } else { typeOf _bp }];
systemChat ("Matrix on. Uniform" + (if (isNull _bp) then { "." } else { " and backpack." }));
