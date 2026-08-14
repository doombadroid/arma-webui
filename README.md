# arma-webui

Build Arma 3 interfaces as HTML, CSS and JavaScript instead of hand-positioned
dialog controls, with a two-way channel to SQF.

Arma 2.20 added `CT_WEBBROWSER`. This is the layer that makes it usable: a
message protocol both directions, the game filesystem exposed to the page,
native text entry, and the diagnostics needed to tell an engine limit from your
own bug — because several things that look like engine limits are not.

```sqf
[_ctrl] call webui_fnc_init;
[_ctrl, "playerInfo", { [name player, getPlayerUID player] }] call webui_fnc_on;
[_ctrl, "money", createHashMapFromArray [["cash", life_cash]]] call webui_fnc_push;
```
```js
WEBUI.on("money", v => render(v.cash));
const info = await WEBUI.call("playerInfo");
```

## Why

A dialog is `idc` numbers, `.paa` art for every panel and state, and a rebuild
to move anything. A page is a stylesheet you can open in a browser tab.

Measured on a real screen: 33 app icons cost **726 KB** as `.paa` against
**12.7 KB** as inline SVG; a phone chassis cost **2.8 MB** as a texture against
**2.2 KB** of CSS; a full colour-scheme variant cost a second 710 KB icon bake
against **227 bytes** of custom properties.

`.paa` still wins for photographs, and it is the only option for world surfaces
and anything drawn over gameplay.

## Requirements

Arma 3 **2.20+** for `CT_WEBBROWSER`, **2.18+** for `toJSON`/`fromJSON`.

## Install

1. Copy `functions/`, `diagnostics/` and `ui/webui.js` into your mission, e.g.
   `<mission>\webui\`.
2. `#include` `config/CfgFunctions.hpp` inside your `CfgFunctions`.
3. `#include` `config/CfgCommands.hpp` in `description.ext`. **Without the
   whitelist nothing works and it fails silently.**
4. `#include` `config/prompt_overlay.hpp` inside a dialog's `class controls`,
   after the browser control, if you want native text entry.
5. Give a dialog a browser control and point it at a page:

```cpp
class Page {
    idc = 4001;
    type = 106;                 // CT_WEBBROWSER
    style = 0;
    x = 0.2; y = 0.2; w = 0.6; h = 0.3;
    colorBackground[] = {0,0,0,0};
    url = "ui\html\mypage.html";   // must match the CfgCommands whitelist
};
```

```sqf
// in the dialog's onLoad
[(_this select 0) displayCtrl 4001] call webui_fnc_init;
```

`ui/demo.html` is a working page that exercises every direction; point a control
at it to check an install.

## API

See **[docs/API.md](docs/API.md)**. Four directions: push, call, call-into-page,
and a one-round-trip boolean. Plus textures and files from the game filesystem,
a native prompt, and volume slaving.

## Read this before debugging anything

**[docs/FINDINGS.md](docs/FINDINGS.md)** — measured engine behaviour, including
several things that are not what they appear:

- **Animation only works when Arma is launched through Steam.** Outside Steam
  the browser is clamped to ~1 fps and every transition looks broken. This cost
  an afternoon and three wrong conclusions.
- **Typed text does reach the DOM.** Real `<input>` is fine. Codebases that
  avoid it are working around a bug that was never verified.
- **`RequestTexture` fails by resolving, not rejecting** — a bad path returns a
  23-character stub that looks like success.
- The browser costs no measurable frame rate.
- The CSS viewport is 30 px per `UI_GRID` unit, independent of screen resolution.
- `ExecJS` carries at least 3.8 MB per call.

## Page rules

- One self-contained `.html` per screen, or one page with view swapping.
- Inline all CSS and JS. **No `<script src>`** — the page has no resolvable base
  URL. Pull scripts with `WEBUI.file()` and eval them.
- No external stylesheets, web fonts or CDNs. System font stack only.
- `fetch`, `XMLHttpRequest`, `localStorage` and `IndexedDB` are blocked. State
  round-trips through SQF.
- Images are data URIs or `WEBUI.texture()`.
- Esc closes the dialog and is handled by Arma. Do not add a page-level handler
  unless you intend to intercept it in SQF.

## Diagnostics

Silent failure is this feature's defining trait, so the tools are part of the
library rather than scaffolding:

| function | answers |
|---|---|
| `webui_fnc_drawRate` | is the engine actually painting? (the launch-path check) |
| `webui_fnc_bench` | what does the browser cost, and what viewport is the page really getting? |
| `webui_fnc_paintProbe` | if it is not painting, which layer is throttling? |
| `webui_fnc_forceProbe` | can any engine-side lever force repaints? |
| `webui_fnc_focusProbe` | does window focus feed the clamp? |
| `webui_fnc_latencyProbe` | what does a message cost, per leg, on both clocks? |

The library also runs one check on its own: **`webui_fnc_clampCheck`**, once
per session on the first ready page, detects the clamped-delivery world from
FINDINGS §1 — the player who launched outside Steam and sees every web screen
at ~1 fps. It forces a short 60 Hz style mutation (an idle sample cannot tell
clamped from healthy, because idle is ~0.6 fps on a healthy client too),
samples the draw rate, and files `webui_clampVerdict` / `webui_clampFps` in
`missionNamespace` plus a `[WEBUI-CLAMP]` RPT line. It presents nothing:
set `webui_onClampVerdict` (code, called with `[verdict, fps]`) to decide what
the player sees, or set `webui_clampCheckDisabled` before init to opt out.

Pages also report uncaught errors and unhandled rejections to the RPT
automatically. A JavaScript error kills a page silently and looks exactly like a
broken feature; one missing `var` under `"use strict"` cost four debugging
rounds before that was added.

## Status

Extracted from a working mission, where it renders a full multi-screen
interface. The measurements in FINDINGS come from one client; the diagnostics
exist so you can confirm them on yours rather than trusting them.

## Security

Handler names are looked up per control, so a page can only reach what was registered for it. That is a convenience boundary, not a trust boundary. Anyone who can run JavaScript in the page can call every registered name with arbitrary arguments, exactly as they could from the debug console. Validate anything that touches money, inventory or permissions server-side.

## Licence

MIT — see [LICENSE](LICENSE). Use it, change it, ship it closed, sell it. The
only condition is that the copyright notice travels with substantial copies, so
keep `LICENSE` alongside the files if you vendor them into a mission.
