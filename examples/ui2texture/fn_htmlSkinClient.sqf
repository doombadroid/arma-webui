/*
    fn_htmlSkinClient.sqf  (webui_fnc_htmlSkinClient) -- the per-viewer half of a server-streamed HTML
    skin. remoteExec'd by fn_htmlSkin to every client (JIP-queued) with the skin id.

    It cannot serve the page at once: the display "apskin_<id>" only exists after this client's
    engine has DRAWN the texture, which means the car has been on screen. So the id goes into a
    wanted-list and a 1 Hz loop serves each display the moment it appears. Idempotent per id.
*/
params [["_id", "", [""]]];
if (!hasInterface || {_id isEqualTo ""}) exitWith {};
if (isNil "webui_htmlSkinWanted") then { webui_htmlSkinWanted = createHashMap; };
if (_id in webui_htmlSkinWanted) exitWith {};
webui_htmlSkinWanted set [_id, "wanted"];
diag_log format ["[WEBUI-HSKIN] client: skin %1 wanted; waiting for display apskin_%1", _id];

if (isNil "webui_htmlSkinLoop") then {
    webui_htmlSkinLoop = true;
    if (isNil "webui_uiTexSkinPreloaded") then {   // the ui2texture mipmap workaround, once per session
        private _tmp = (findDisplay 46) createDisplay "webui_uiTexSkin";
        _tmp closeDisplay 1;
        webui_uiTexSkinPreloaded = true;
    };
    [] spawn {
        private _tick = 0;
        while { true } do {
            uiSleep 1; _tick = _tick + 1;
            {
                private _id = _x; private _state = _y;
                private _d = findDisplay ("apskin_" + _id);
                if (_state isEqualTo "wanted" && { !isNull _d }) then {
                    private _c = _d displayCtrl 941931;
                    if (!isNull _c) then {
                        if ([_c] call webui_fnc_init) then {
                            // the page: serve the server's skins\<id>.html over the placeholder
                            [_c, format ["skins\%1.html", _id]] call webui_fnc_serve;
                            webui_htmlSkinWanted set [_id, "served"];
                            _c setVariable ["webui_hskinDraws", 0];
                            _c ctrlAddEventHandler ["Draw", {
                                params ["_c"];
                                private _k = (_c getVariable ["webui_hskinDraws", 0]) + 1;
                                _c setVariable ["webui_hskinDraws", _k];
                                if (_k isEqualTo 1) then { _c setVariable ["webui_hskinFirstAt", diag_tickTime]; diag_log format ["[WEBUI-HSKIN] client: %1 first paint at frame %2", ctrlParent _c, diag_frameNo]; };
                            }];
                            diag_log format ["[WEBUI-HSKIN] client: display for %1 appeared; page requested from the server", _id];
                        };
                    };
                };
                // a served skin gets pumped until 3 s after its FIRST paint (the document rewrite is a few
                // frames; a static page then paints once or twice and never again -- a paint COUNT never
                // reaches a threshold, which is why the first live run pumped forever), then left frozen
                if (_state isEqualTo "served") then {
                    [_d, _id] call { params ["_d", "_id"];
                        private _c = _d displayCtrl 941931;
                        private _k = _c getVariable ["webui_hskinDraws", 0];
                        private _t0 = _c getVariable ["webui_hskinFirstAt", -1];
                        if (_t0 < 0 || { diag_tickTime - _t0 < 3 }) then { displayUpdate _d; } else {
                            if !(_c getVariable ["webui_hskinFrozen", false]) then {
                                _c setVariable ["webui_hskinFrozen", true];
                                _c ctrlWebBrowserAction ["StopBrowser"];
                                diag_log format ["[WEBUI-HSKIN] client: %1 frozen after %2 paints -- browser stopped, no further updates", _id, _k];
                            };
                        };
                    };
                };
            } forEach webui_htmlSkinWanted;
            // the eviction probe: once a minute, is every served display still there?
            if ((_tick mod 60) isEqualTo 0) then {
                { if (_y isEqualTo "served") then {
                    diag_log format ["[WEBUI-HSKIN] t+%1 min: display apskin_%2 %3", _tick / 60, _x, ["GONE", "alive"] select (!isNull (findDisplay ("apskin_" + _x)))];
                }; } forEach webui_htmlSkinWanted;
            };
        };
    };
};
