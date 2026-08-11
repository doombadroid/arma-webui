// SPDX-License-Identifier: MIT
/*
    fn_webOn.sqf -- register a handler a page may call.

    Per control, not global: a page can only reach names registered on its own
    browser control, so one screen cannot call another screen's verbs. That is a
    convenience boundary, NOT a trust boundary -- anyone who can run JS in the
    page can call every registered name with arbitrary args, exactly as they
    could from the debug console. Validate server-side.

    The handler receives the page's argument array as _this and its return value
    is sent back. Returning nil is fine; the page sees null.

    Usage:
        [_ctrl, "gangInfo", { [life_gang_data select 1, count life_gangMembersList] }] call webui_fnc_on;

    Page side:
        const info = await WEBUI.call("gangInfo");
*/

params [["_ctrl", controlNull, [controlNull]], ["_name", "", [""]], ["_code", {}, [{}]]];
if (isNull _ctrl) exitWith { false };
if (_name isEqualTo "") exitWith { false };

private _api = _ctrl getVariable ["webui_api", createHashMap];
_api set [_name, _code];
_ctrl setVariable ["webui_api", _api];
true
