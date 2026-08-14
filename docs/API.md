# arma-webui — API

Four directions. The page and SQF are peers; either can call the other.

## SQF -> page

```sqf
[_ctrl, "money", createHashMapFromArray [["cash", 4200], ["bank", 91000]]] call webui_fnc_push;
```
```js
WEBUI.on("money", v => render(v));   // replays the last value on subscribe
WEBUI.get("money");                  // last value, or undefined
```

Payloads are serialised with `toJSON`, so a HashMap arrives as a real
JavaScript object with the same keys. Supported: Boolean, Number, String,
Array, HashMap (string keys), nil. Anything else becomes null.

Queued through `webui_fnc_exec`, so a push sent before the page has loaded is
delivered on load rather than dropped.

## page -> SQF

```sqf
[_ctrl, "playerInfo", { [name player, getPlayerUID player] }] call webui_fnc_on;
```
```js
const info = await WEBUI.call("playerInfo");   // ~21 ms median at 1 KB (FINDINGS 5)
```

Handlers are registered per control, so one page cannot reach another's verbs.
That is a convenience boundary, **not** a trust boundary — see Security.

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
const name = await WEBUI.call("prompt", ["Rename", current, 24], 60000);
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
