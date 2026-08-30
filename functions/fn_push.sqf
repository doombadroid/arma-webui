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

    Queued through webui_fnc_exec, so a push sent before the bridge exists is
    held and delivered once it does -- not dropped. The delivery moment is the
    page proving window.WEBUI exists (a HELLO or any inbound message), NOT
    PageLoaded: that marks the document loaded and deliberately leaves the queue
    held. Returns false if the name was refused or the queue was full, in which
    case the payload was discarded rather than delayed.
*/

// _value takes NO type filter on purpose. A filter substitutes its default
// when the input is nil or the wrong type, so an unsupported payload -- or an
// explicit nil -- silently arrived in the page as the empty string, while both
// the docstring above and docs/API.md promised null. A page written to the
// documented contract (`if (v === null)`) therefore never saw null; it saw "".
params [
    ["_ctrl",    controlNull, [controlNull]],
    ["_channel", "",          [""]]
];
private _value = if (count _this > 2) then { _this select 2 } else { nil };

if (isNull _ctrl) exitWith { false };
if (_channel isEqualTo "") exitWith { diag_log "[WEBUI] empty channel"; false };

// The channel name becomes a JavaScript string literal below and, unlike the
// payload, was never base64'd: a name containing an apostrophe (format
// ["gang_%1", _gangName] with "O'Malley") closed the literal early and the
// whole statement died as a SyntaxError that ExecJS reports nowhere -- the push
// simply vanished while this function still returned true. It was equally an
// injection path into the page for any name derived from player text.
if !(_channel regexMatch "^[A-Za-z_][A-Za-z0-9_.-]*$") exitWith {
    diag_log format ["[WEBUI] push refused '%1' -- channel must match [A-Za-z_][A-Za-z0-9_.-]*", _channel];
    false
};

// nil is encoded explicitly -- the BIKI says it "cannot be passed directly as
// the command would simply not execute". A top-level unsupported type is a
// separate case: toJSON returns an EMPTY STRING for it, not "null", so it is
// mapped below or the page receives an empty payload instead of the documented
// null. Unsupported values nested in an Array or HashMap are already null.
private _json = if (isNil "_value") then { "null" } else { toJSON _value };
if (_json isEqualTo "") then {
    diag_log format ["[WEBUI] push '%1': unsupported payload type (%2) -- sending null",
        _channel, typeName _value];
    _json = "null";
};
private _b64 = _ctrl ctrlWebBrowserAction ["ToBase64", _json];
[_ctrl, format ["window.WEBUI && WEBUI._emit('%1','%2');", _channel, _b64]] call webui_fnc_exec
