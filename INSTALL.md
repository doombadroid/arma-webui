# Install checklist

Five things. Miss either of the first two and it fails **silently** — the page
renders perfectly and simply cannot talk to the game.

1. **Files** — `functions/`, `diagnostics/`, `ui/webui.js` into the mission.
2. **`CfgFunctions`** — `#include "webui\config\CfgFunctions.hpp"`.
   Check with `isNil "webui_fnc_init"` in the debug console; `false` is good.
3. **`description.ext`** — `#include "webui\config\CfgCommands.hpp"`.
   The page's path must match the whitelist. This is precondition one.
4. **A `JSDialog` handler** — you get this by calling `webui_fnc_init` on the
   control. This is precondition two.
5. **`webui.js` reachable** — the page pulls it with `WEBUI.file()` and SQF
   re-injects it on load; both need the path to be right.

## Verifying

Point a control at `ui/demo.html` and open it. Expect in the RPT:

```
[WEBUI] initialised (4-way) t=...
[WEBUI] mission root: mpmissions\__CUR_MP.<map>\
```

and in the page, a live bridge with working call buttons.

Then:

```sqf
[] spawn webui_fnc_drawRate;
```

If it reports ~1 fps, **the game was not launched through Steam** — that is the
first thing to rule out, before anything else. See docs/FINDINGS.md.

## Common failures

| symptom | cause |
|---|---|
| page renders, calls never arrive | path not in `allowedHTMLLoadURIs`, or `webui_fnc_init` never called |
| page blank | `<script src>` in the page — it cannot resolve |
| animation frozen, buttons laggy | launched outside Steam |
| a feature "does nothing" | a JS error killed the page — check the RPT for `JS ERROR` |
| `texture()` gives a broken image | bad path; it resolves with a stub instead of rejecting |
| pushes never arrive | sent before the page was up — use `webui_fnc_push`, which queues |
