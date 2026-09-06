# HTML on a 3D model

Everything measured in [FINDINGS §12](../../docs/FINDINGS.md), as runnable code. A
`CT_WEBBROWSER` inside a UI-on-texture display paints onto any hidden selection —
cars, uniforms, backpacks, props with a config class — at one browser paint per game
frame, to every viewer, JIP-safe, with no client download for the art.

## The chain, once

```
page (self-contained HTML) ─► display class (never opened on screen) ─► texture string
   #(rgb,512,512,1)uiEx(display:webui_uiTexDemo,uniqueName:<name>)
─► setObjectTextureGlobal [sel, string]      the STRING replicates, JIP-safe
─► each viewer's engine creates the display on first draw of the texture
─► each viewer pumps it (animated) or paints it once and freezes it (static)
```

The string carries everything except the pump. That is why every animated surface
has a per-viewer half that is `remoteExec`'d.

## Files

| file | role |
|---|---|
| `webui_uiTexDemo.hpp` · `matrix.html` · `fn_uiTexDemo.sqf` | the first probe: rain on a car, the frame-counter pass/fail |
| `fn_uiTexManager.sqf` | **the one pump.** Registers `[object, display]`; each frame sorts by camera distance and pumps the nearest `webui_uiTexCap` (20), `StopBrowser` beyond it. Never prunes on a missing display — it appears on first draw, after registration |
| `fn_uiTexLiveClient.sqf` | per-viewer half of an ANIMATED surface: registers with the manager. `remoteExec` it to all, `jip = 1` |
| `fn_wearPage.sqf` | the page as a CLOTHING skin: uniform (selection 0) + backpack, global, every viewer registered |
| `webui_uiTexSkin.hpp` · `skin.html` · `fn_htmlSkin.sqf` · `fn_htmlSkinClient.sqf` · `make_skin_page.py` | **server-streamed static skins.** Art lives on the server as a page; each viewer fetches it through `webui_fnc_serve` when the display appears; paint once, freeze, stop the browser. One display per SKIN, shared by every object wearing it |
| `webui_uiTexStatic.hpp` · `static.html` · `fn_staticPump.sqf` · `fn_reskinBurst.sqf` | two seconds of broadcast TV static, then a stock livery lands (`BIS_fnc_initVehicle`, array form) |
| `fn_uiTexBench.sqf` | N non-physics cars wearing a live page; `diag_fps` before/during/after |

## Wire it

1. Include the `.hpp` displays where your dialogs are; put the pages under a path
   `allowedHTMLLoadURIs` covers and fix each `url=`.
2. Register the functions under your CfgFunctions tag (they are written as `webui_fnc_*`).
3. `CfgRemoteExec` (mode 1):
   ```cpp
   class webui_fnc_uiTexLiveClient { allowedTargets = 1; jip = 1; };
   class webui_fnc_htmlSkinClient  { allowedTargets = 1; jip = 1; };
   class webui_fnc_staticPump      { allowedTargets = 1; };
   ```
   They carry ids only; page markup always comes from the server through your
   `webui_serveFetcher` (see `docs/API.md`).
4. Skins: `python3 make_skin_page.py livery.png <server page root>/skins/my_livery.html`,
   then `[_veh, "my_livery"] call webui_fnc_htmlSkin;`.

## Rules for a page on a model (give these to your designer)

- **Self-contained and self-driving.** No fetch, fonts or external files; images as data URIs;
  canvas or CSS. And nothing arrives from SQF later: ExecJS does not execute in an
  in-texture browser (§12), so a page gets its state from its own markup, `RequestFile`
  and `RequestTexture` only. Page → SQF calls still work.
- **It is a UV sheet, not a shape.** The page is stretched over the model's texture layout.
  A uniform is a patchwork of islands; a car is a flattened body. Design on the sheet.
- **`A3API.RequestTexture("<the model's own _co.paa>", 1024)`** hands the page the real base
  texture as a data URL. Draw it first, composite effects over it — the effect follows the
  seams instead of cutting across them. This is the difference between a gimmick and a livery.
- **Square.** `uiEx` renders 1:1; a non-square texture stretches. 512 is plenty at read distance.
- **Two cost classes.** Static: paint once, freeze, free — stream as many as you like.
  Animated: ~0.3 ms of frame time per surface per viewer, nearest 20 pumped. Pulse and
  glitch generously; do not run 60 fps video across a crowd.
- **What can wear it.** Anything whose class has `hiddenSelections`: vehicles, uniforms,
  backpacks, classed props. Vests, headgear, goggles have none. `createSimpleObject [<p3d>]`
  objects take neither textures nor `addAction`.

## Read the result

Corner counters on the probe pages: `f` climbing = live; stuck at `f 1` = not pumped;
black = the browser never painted (check the launch path, §1). RPT tags:
`[WEBUI-UITEX]`, `[WEBUI-HSKIN]`, `[WEBUI-SKIN]`.
