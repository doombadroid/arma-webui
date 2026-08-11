// SPDX-License-Identifier: MIT
/*
    fn_webPush.sqf -- push a value into a web UI page. SQF -> JS.

    Usage:
        [_ctrl, "stats", createHashMapFromArray [["cash", 12500], ["name", name player]]]
            call webui_fnc_push;

    Page side:
        WEBUI.on("stats", v => render(v));      // v.cash, v.name

    The payload is serialised with toJSON, so a HashMap arrives as a real
    JavaScript object and strings are escaped properly. This replaced `str`,
    which forced every payload to be a positional array -- a contract that lived
    in two files at once and drifted silently -- and which produced invalid JSON
    the moment a player's name contained a quote.

    Supported: Boolean, Number, String, Array, HashMap (string keys), nil.
    Anything else (objects, control refs, code) serialises to null.

    Then base64, because the result is interpolated into JavaScript SOURCE by
    format[] -- a quote or newline in the data would break the statement.

    Queued through webui_fnc_exec, so a push sent before the page has loaded
    is delivered on PageLoaded rather than dropped.
*/

params [
    ["_ctrl",    controlNull, [controlNull]],
    ["_channel", "",          [""]],
    ["_value",   "",          ["", 0, [], true, createHashMap]]
];

if (isNull _ctrl) exitWith { false };
if (_channel isEqualTo "") exitWith { diag_log "[WEBUI] empty channel"; false };

private _b64 = _ctrl ctrlWebBrowserAction ["ToBase64", toJSON _value];
[_ctrl, format ["window.WEBUI && WEBUI._emit('%1','%2');", _channel, _b64]] call webui_fnc_exec;
true
