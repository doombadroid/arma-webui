# arma-webui — API

Four directions. The page and SQF are peers; either can call the other.

## SQF -> page

```sqf
[_ctrl, "money", createHashMapFromArray [["cash", 4200], ["bank", 91000]]] call webui_fnc_push;
```
```js
WEBUI.on("money", v => render(v));   // replays the last value on subscribe
WEBUI.get("money");                  // last value, or undefined
WEBUI.off("money", render);          // one subscriber
WEBUI.off("money");                  // every subscriber on the channel
```

`on()` **appends** — unlike `handle()` and `webui_fnc_on`, which both overwrite
by name. A view that re-subscribes each time it is entered accumulates
subscribers and runs its renderer once per past visit, so a page with view
swapping should `off()` on the way out.

Payloads are serialised with `toJSON`, so a HashMap arrives as a real
JavaScript object with the same keys. Supported: Boolean, Number, String,
Array, HashMap (string keys), nil. Anything else becomes null.

Queued through `webui_fnc_exec`, so a push sent before the bridge exists is
**held and delivered once it does** — not dropped. The delivery moment is the
page proving `window.WEBUI` exists (a `HELLO`, or any inbound message), **not**
`PageLoaded`: that marks the document loaded and deliberately leaves the queue
held, because firing it into a document without the bridge loses it silently.
A page that never gets the bridge therefore never receives the queue — that is
the `timer` case in INSTALL's triage, and `webui_fnc_bootProbe` reports it as
"page loaded, but the bridge never appeared".

*Replies to a page's own `WEBUI.call` are the exception and are never queued* —
a reply is scoped to the document that asked, so if the bridge is down it is
dropped and the caller times out, rather than being replayed into a later
document whose call ids would collide with it.

`webui_fnc_push` returns `false` if the name was refused or the queue is full (200 statements — a page that never loads
must not grow it without bound); a `false` return means the payload was
discarded, not delayed.

## page -> SQF

```sqf
[_ctrl, "playerInfo", { [name player, getPlayerUID player] }] call webui_fnc_on;
```
```js
const info = await WEBUI.call("playerInfo");   // ~21 ms median at 1 KB (FINDINGS 5)
```

Handlers are registered per control, so one page cannot reach another's verbs.
That is a convenience boundary, **not** a trust boundary — see Security.

Inside a handler, `_webuiCtrl` is the control the page called through. Use it
rather than `uiNamespace getVariable "WEBUI_ctrl"`, which is the *last* control
initialised and is a different control as soon as two pages are live.

Unregister with `webui_fnc_off`:

```sqf
[_ctrl, "playerInfo"] call webui_fnc_off;   // one name
[_ctrl] call webui_fnc_off;                 // all of them
```

Anything that registers a handler temporarily — every diagnostic in this
library does — must take it back off, or it stays callable on the operator's
live page for the rest of that page's life.

`webui_fnc_init` registers these on every control: `log`, `ping`,
`playerInfo`, `serverTime`, `screenSize`, `ctrlInfo` (returns
`[idc, ctrlPosition]`) and `promptText`.

## Channel and handler names

Every channel and handler name must match `[A-Za-z_][A-Za-z0-9_.-]*`.

Names are interpolated into JavaScript source, and only the *payload* is
base64'd — so a name carrying an apostrophe (`format ["gang_%1", _gangName]`
with `O'Malley`) used to close the string literal early and kill the statement
as a syntax error that `ExecJS` reports nowhere: the push vanished while
`webui_fnc_push` still returned `true`. Build names from constants, not from
player text. A refused name logs to the RPT and returns `false` (push) or `nil`
(call).

## SQF -> page, with a return value

```js
WEBUI.handle("selectedRow", () => state.selected);  // may return a Promise
```
```sqf
private _row = [_ctrl, "selectedRow"] call webui_fnc_call;   // needs a scheduled context
```

Costs ~2 ms over the raw transport, ~14 ms median round trip at 1 KB
(FINDINGS 5). The page's reply must fit the 10240-char channel cap: the
engine truncates every page-to-SQF message (SendAlert and SendConfirm
alike) at exactly 10 KiB, envelope included, measured to the character in
FINDINGS 5. `webui.js` turns an oversized reply into a named error instead
of letting the truncation present as a timeout. Big data belongs in the
other direction; SQF to page carries 4 MB intact.

## page -> SQF, boolean, one round trip

```js
const isCop = await WEBUI.ask("isCop");   // bool only; no ExecJS reply leg.
                                          // ~14.5 ms median, ~0.7x call() (FINDINGS 5)
```

The handler's return value *is* the answer, so it runs unscheduled and must not
suspend.

**It also blocks the page.** The handler runs inside the `JSDialog` handler
while the page sits in `SendConfirm`, so the entire document is frozen for as
long as it takes — not just this call. A handler that runs long enough logs
`[WEBUI] SLOW ask(...)` with the elapsed time. The trip point is 5 ms *or*
twice `diag_tickTime`'s current resolution, whichever is larger — that clock is
single precision and coarsens with client uptime, so on a long-lived client the
threshold rises with it rather than reporting quantisation as slowness. If the work is not trivial, use
`webui_fnc_on` + `WEBUI.call` instead: that path is spawned and the page keeps
running while it waits.

> **The millisecond figures above inherit a caveat.** They come from FINDINGS 5,
> whose samples are differences of two `diag_tickTime` reads — a single-precision
> clock whose step grows with client uptime (~7.8 ms after a day). The uptime at
> capture was not recorded, so treat them as order-of-magnitude until re-measured
> on a freshly started client. `webui_fnc_latencyProbe` now prints the live clock
> quantum before every run.

## The game filesystem, from the page

```js
const url = await WEBUI.texture("icons\\myicon.paa", 256);  // data URL
img.src = url;   el.style.backgroundImage = `url(${url})`;  // both work

const raw = await WEBUI.file("ui\\html\\webui.js");          // like loadFile
const cfg = await WEBUI.preprocessed("config\\prices.hpp");  // like preprocessFile
```

`texture()` resolves mission-relative paths automatically — see FINDINGS.

## Native text entry

Typed text reaches the DOM normally, so a real `<input>` is fine. This exists
for a native-looking prompt, or when the browser is frozen:

```js
const name = await WEBUI.call("promptText", ["Rename", current, 24], 60000);
if (name !== null) apply(name);      // null = cancelled
```

## Audio that obeys the game

The browser plays through the OS mixer, so the game's volume sliders do not
reach it. SQF can read them and the page can obey:

```sqf
[_ctrl] spawn webui_fnc_volumeSlave;              // or [_ctrl, _emitter, _range]
```
```js
WEBUI.on("vol", v => { gain.gain.value = userVolume * v.music * v.dist; });
```

## Freezing

```sqf
[_ctrl, false] call webui_fnc_freeze;   // last frame stays, browser shuts down
[_ctrl, true]  call webui_fnc_freeze;   // reloads: channels must be re-pushed
```

Frees the browser's memory. Not a frame-rate optimisation — see FINDINGS.

## Launch-clamp detection

```sqf
// automatic: fn_init arms it on the first ready page, once per session
missionNamespace setVariable ["webui_onClampVerdict", {
    params ["_verdict", "_fps"];
    if (_verdict isEqualTo "clamped") then {
        systemChat "web UI is frame-clamped -- launch the game through Steam";
    };
}];
// opt out entirely (set BEFORE the first webui_fnc_init):
missionNamespace setVariable ["webui_clampCheckDisabled", true];
```

Detects the FINDINGS §1 world — launched outside Steam, delivery clamped to
~1 fps — by forcing a brief style mutation and sampling the draw rate; an idle
sample cannot distinguish clamped from healthy. Results land in
`webui_clampVerdict` (`"healthy"|"clamped"`) and `webui_clampFps`. The library
never presents anything itself.

## Security

Handler names are looked up per control, so a page can only reach what was
registered for it. **That is a convenience boundary, not a trust boundary.**
Anyone who can run JavaScript in the page can call every registered name with
arbitrary arguments, exactly as they could from the debug console. Validate
anything that touches money, inventory or permissions server-side.
