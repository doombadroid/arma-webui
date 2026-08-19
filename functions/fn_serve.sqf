// SPDX-License-Identifier: MIT
/*
    fn_serve.sqf  (webui_fnc_serve) -- let the SERVER replace a page's markup at
    open time, so UI ships without a client repack.

        [_ctrl, "ui\html\deck.html"] call webui_fnc_serve;

    THE PROBLEM THIS SOLVES. A CT_WEBBROWSER page has to live at a path listed
    in CfgCommands::allowedHTMLLoadURIs, which in practice means inside the
    mission PBO. Changing one line of HTML therefore changes the mission, and
    every connected client re-downloads the whole PBO -- 230 MB in the mission
    this was written for, to ship 200 KB of markup. That cost is why UI work
    batches up instead of shipping continuously.

    THE SHAPE. This is an OVERRIDE, not a replacement, and the distinction is
    the whole safety argument:

      - the page still loads from the PBO exactly as it does today, and renders
        with no server involvement at all;
      - once it is up, the client asks the server whether it holds a different
        version of that page;
      - if it does, the bytes come back and are written over the live document;
      - if the server is silent, older, has nothing, or is not running this at
        all, NOTHING HAPPENS and the PBO page stands.

    So the failure mode of the whole feature is "you get what you have today".
    A page can never end up blank because of this: the fallback is not a code
    path that has to run correctly, it is the absence of one.

    The PBO copy is a BASELINE, not a build artifact -- it never has to be
    updated again. Ship UI by writing files where the server reads them.

    WHY IT CAN CARRY A WHOLE PAGE. Measured in docs/FINDINGS.md section 5: the
    page-to-SQF direction truncates at exactly 10240 characters, but the
    SQF-to-page direction has no such limit and carried a 3.8 MB payload intact.
    This only ever pushes large data toward the page, so it rides the direction
    that has room. The NETWORK leg (server -> client) is the constrained one and
    is chunked by the host's transport, not here.

    HOW THE DOCUMENT IS REPLACED. document.open()/write()/close(), not
    innerHTML. Scripts inserted via innerHTML never execute, which would leave
    every page's behaviour dead while its markup looked right -- the worst
    possible failure for a UI system. document.write executes them. The window
    object survives, so WEBUI and the A3API binding established at load are
    still there for the incoming document.

    SECURITY. Page markup is executable content, so where it comes from is a
    trust decision, not a transport detail:

      - The host's fetcher MUST be server-authoritative and MUST NOT accept
        markup relayed from another client. Wire the remoteExec entry so only
        the server can reach the receiving client (allowedTargets = 1); a
        client-to-client path here is arbitrary script execution inside a
        document that holds A3API.
      - This never evaluates what it receives as SQF, and never compiles it.
        It is treated as opaque bytes and handed to the page.

    Usage, once per page open, after webui_fnc_init:

        [_ctrl, _pageId] call webui_fnc_serve;

    The host supplies the transport by registering a fetcher ONCE at init:

        webui_serveFetcher = {
            params ["_pageId", "_have", "_cb"];
            // ... ask the server; call [_markupOrEmpty] call _cb when it answers
        };

    _have is what the client already has for that page (a version tag, "" if
    unknown), so a host that tracks versions can answer "unchanged" cheaply
    instead of shipping bytes on every open.
*/

params [["_ctrl", controlNull, [controlNull]], ["_pageId", "", [""]], ["_timeout", 5, [0]]];
if (isNull _ctrl) exitWith { false };
if (_pageId isEqualTo "") exitWith { false };

// Off unless the host wired a transport. A mission that never sets a fetcher
// keeps its PBO pages and pays nothing for this file existing.
private _fetcher = missionNamespace getVariable ["webui_serveFetcher", {}];
if !(_fetcher isEqualType {}) exitWith { false };
if (_fetcher isEqualTo {}) exitWith { false };
if !(missionNamespace getVariable ["webui_serveEnabled", true]) exitWith { false };

// ---------------------------------------------------------------- cache
// Per session, keyed by page id. An override that has already arrived is
// reapplied locally on the next open with no server round trip, so repeatedly
// opening a screen costs one fetch, not one per open.
private _cache = uiNamespace getVariable ["webui_serveCache", createHashMap];
uiNamespace setVariable ["webui_serveCache", _cache];

private _apply = {
    params ["_c", "_markup"];
    if (isNull _c) exitWith { false };
    if !(_markup isEqualType "") exitWith { false };
    if (_markup isEqualTo "") exitWith { false };
    // Same codec as webui_fnc_push, deliberately: toJSON then the engine's own
    // ToBase64. Markup is interpolated into JavaScript SOURCE by ExecJS, and raw
    // HTML inside a JS string literal is a quoting minefield -- every quote,
    // newline and backslash in the page would have to survive. Base64 sidesteps
    // all of it, and reusing push's exact path means _serve decodes through the
    // same UTF-8-aware helper that every other channel already proves works.
    private _b64 = _c ctrlWebBrowserAction ["ToBase64", toJSON _markup];
    [_c, format ["window.WEBUI && WEBUI._serve('%1');", _b64]] call webui_fnc_exec;
    true
};

private _hit = _cache getOrDefault [_pageId, ""];
if (_hit isNotEqualTo "") exitWith { [_ctrl, _hit] call _apply };

// ---------------------------------------------------------------- fetch
// The host's fetcher is asynchronous and may never answer -- a server that is
// not running this feature simply will not reply. That is not an error state
// and must not be reported as one: the PBO page is already on screen.
private _done = false;
private _cb = {
    params [["_markup", "", [""]]];
    if (_markup isEqualTo "") exitWith {};
    private _cc = uiNamespace getVariable ["webui_serveCache", createHashMap];
    _cc set [_pageId, _markup];
    [_ctrl, _markup] call _apply;
};

[_pageId, "", _cb] call _fetcher;
true
