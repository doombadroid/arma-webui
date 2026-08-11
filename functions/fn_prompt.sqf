// SPDX-License-Identifier: MIT
/*
    webui_fnc_prompt.sqf -- native text entry for web UI pages.

    Typed text reaches the DOM normally, so a real <input> in a page works and
    this is OPTIONAL. It exists for a native-looking prompt, and for when the
    browser is frozen.

    Shows an overlay in the SAME dialog as the browser -- a second dialog would
    fight over focus -- waits for OK/Cancel, and returns the string.

    Called from a page over the bridge:
        const name = await WEBUI.call("promptText", ["Rename gang", current, 24]);
        if (name !== null) { ... }          // null = cancelled

    Returns the entered string, or nil on cancel. Runs in a scheduled context
    (the bridge dispatcher spawns handlers), so waitUntil here is safe.
*/

params [
    ["_title",   "Enter text", [""]],
    ["_prefill", "",           [""]],
    ["_max",     64,           [0]]
];

disableSerialization;
// resolve the hosting display from the browser control published by
// webui_fnc_init, so this works for any dialog, not just the demo
private _webCtrl = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
if (isNull _webCtrl) exitWith { diag_log "[PROMPT] no web control registered"; nil };
private _display = ctrlParent _webCtrl;
if (isNull _display) exitWith { nil };

private _ids  = [937410, 937411, 937412, 937413, 937414, 937415];
private _edit = _display displayCtrl 937413;
if (isNull _edit) exitWith {
    diag_log "[PROMPT] overlay controls missing from the dialog";
    nil
};

// seed the field and title
(_display displayCtrl 937412) ctrlSetStructuredText parseText format [
    "<t size='1' font='RobotoCondensed' color='#c9e21a'>%1</t>", _title
];
_edit ctrlSetText (_prefill select [0, _max]);

with uiNamespace do { WEBUI_promptDone = 0; WEBUI_promptResult = nil; };

{ (_display displayCtrl _x) ctrlShow true; } forEach _ids;
ctrlSetFocus _edit;

// wait for a button, or for the dialog to go away under us
waitUntil {
    (with uiNamespace do { WEBUI_promptDone }) isEqualTo 1
    || { isNull (ctrlParent _webCtrl) }
};

{ (_display displayCtrl _x) ctrlShow false; } forEach _ids;

private _out = with uiNamespace do { WEBUI_promptResult };
with uiNamespace do { WEBUI_promptDone = 0; WEBUI_promptResult = nil; };

if (isNil "_out") exitWith { nil };
if !(_out isEqualType "") exitWith { nil };

_out select [0, _max]
