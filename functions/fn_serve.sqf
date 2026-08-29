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

    THE CALLBACK IS SAFE TO HOLD AND CALL LATER, from any scope -- a spawn, a
    remoteExec'd handler, a network reply minutes afterwards. That is the point
    of it, and it is worth stating because it was not true before: the callback
    used to reach for this function's local variables, which do not survive
    outside its own call stack, so only a fetcher that answered synchronously
    ever worked. Answer once; a second answer on the same callback is ignored.

    Not answering at all is a supported outcome and needs no cleanup from the
    host. The pending entry expires after _timeout seconds (default 5) and the
    PBO page simply stands, which is what it was already doing.
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
//
// SQF CODE DOES NOT CAPTURE LOCALS, AND THAT BROKE THIS ENTIRELY.
// The callback below used to reference _pageId, _ctrl and _apply directly. A
// `call`ed block runs in the CALLER's scope chain, so that worked only while
// the fetcher invoked the callback synchronously, inside this function's own
// call stack. The documented case is the other one: a fetcher that asks the
// server and answers later, from a spawn or a remoteExec'd handler. By then
// this scope is gone, all three names are undefined, and the callback dies on
// "Undefined variable" -- silently, because a dead script drops the override
// and the PBO page stays up, which is exactly what success looks like here.
// So the feature's own headline use case never worked.
//
// The fix is a TICKET. Each fetch gets an integer, the context is parked in
// uiNamespace under it, and the callback is compiled with only that integer
// baked into its source -- so it depends on nothing but globals.
//
// The ticket is an INTEGER on purpose. Baking the page id into compiled source
// would put caller-supplied text inside an SQF literal, one quote away from
// being an injection site in a file whose whole security argument is that it
// never compiles what it is given. A number cannot carry a quote.
private _recv = {
    params ["_ticket", "_args"];
    private _pend = uiNamespace getVariable ["webui_servePending", createHashMap];
    private _ctx = _pend getOrDefault [_ticket, []];
    if (_ctx isEqualTo []) exitWith {};          // timed out, or answered twice
    _pend deleteAt _ticket;                       // one answer per ticket
    _ctx params ["_c", "_pid", "_applyFn"];

    // The documented call is [_markup] call _cb, but a host that passes the
    // bare string is not doing anything unreasonable -- accept both rather than
    // fail on a detail no compiler checks.
    private _markup = "";
    if (_args isEqualType []) then {
        if (count _args > 0) then { _markup = _args select 0 };
    } else { _markup = _args };
    if !(_markup isEqualType "") exitWith {};
    if (_markup isEqualTo "") exitWith {};        // "nothing to serve" is normal

    private _cc = uiNamespace getVariable ["webui_serveCache", createHashMap];
    _cc set [_pid, _markup];
    [_c, _markup] call _applyFn;
};
uiNamespace setVariable ["webui_serveRecv", _recv];

private _pend = uiNamespace getVariable ["webui_servePending", createHashMap];
uiNamespace setVariable ["webui_servePending", _pend];
private _ticket = (uiNamespace getVariable ["webui_serveSeq", 0]) + 1;
uiNamespace setVariable ["webui_serveSeq", _ticket];
_pend set [_ticket, [_ctrl, _pageId, _apply]];

private _cb = compile format
    ["[%1, _this] call (uiNamespace getVariable ['webui_serveRecv', {}]);", _ticket];

// _timeout used to be declared and never read, advertising a bounded wait that
// did not exist. It bounds the PENDING ENTRY, not the page: a fetcher that
// never answers would otherwise pin a control reference in uiNamespace for the
// rest of the session, once per page open. Expiry changes nothing on screen --
// the PBO page has been up since before this function ran.
[_ticket, _timeout] spawn {
    params ["_ticket", "_timeout"];
    uiSleep _timeout;
    private _pend = uiNamespace getVariable ["webui_servePending", createHashMap];
    if (_ticket in _pend) then {
        _pend deleteAt _ticket;
        diag_log format ["[WEBUI] serve: fetch %1 expired after %2s (no reply; PBO page stands)",
            _ticket, _timeout];
    };
};

[_pageId, "", _cb] call _fetcher;
true
