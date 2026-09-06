# HTML on a 3D model

The probe behind [FINDINGS §12](../../docs/FINDINGS.md#12-a-browser-inside-a-ui-on-texture-display-paints-at-frame-rate):
a `CT_WEBBROWSER` inside a UI-on-texture display, painted onto a vehicle. Matrix
rain on a car, at the game's frame rate. Three files:

| file | what |
|---|---|
| `webui_uiTexDemo.hpp` | the display — never opened on screen, only *named* in the texture string |
| `matrix.html` | the page — self-contained canvas, draws a frame counter so pass/fail is visible on the model |
| `fn_uiTexDemo.sqf` | applies the string to every hidden selection and pumps `displayUpdate` |

## Wire it

1. `#include "webui_uiTexDemo.hpp"` where your dialogs are included; put
   `matrix.html` under a path `allowedHTMLLoadURIs` covers and fix the `url=`.
2. Register `fn_uiTexDemo.sqf` under your CfgFunctions tag (or `execVM` it).
3. In game, look at a car: `[] call webui_fnc_uiTexDemo;`. Again to switch off.

## Read the result

| on the model | meaning |
|---|---|
| rain moving, `f NNN` climbing | whole chain live |
| frozen at `f 1` | display rendered once; `displayUpdate` not reaching it |
| black | display exists, browser never painted — check launch path (§1) |
| original paint + "no hidden selections" | that class cannot be textured |

The RPT carries `[WEBUI-UITEX]` lines: selection count, the exact string, the
frame the display appeared, browser `Draw` at #1 / #60 / #600.

## Laws (measured)

- Preload the display once (`createDisplay` → `closeDisplay 1`) or the first use
  throws "Cannot load mipmap".
- The display is created by the first texture draw; `findDisplay` is null until
  then. Unique names are lowercase.
- No `displayUpdate`, no motion. Stop the pump and the last frame stays.
- `#reset` frees everything; the engine drops the display on its own.
- Local `setObjectTexture`. `Global` broadcasts the string and every client
  spins up its own browser.
- Display coords are 0..1, rendered square. Not safezone.
- Only classes with `hiddenSelections`. Super-simple objects
  (`createSimpleObject [<p3d>,…]`) take neither textures nor `addAction`.
