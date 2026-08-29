# Install checklist

Six things. Miss either of the first two and it fails **silently** — the page
renders perfectly and simply cannot talk to the game. Miss the sixth and it
works, but every screen takes a visible moment to populate.

1. **Files** — `functions/`, `diagnostics/`, `ui/webui.js` into the mission.
2. **`CfgFunctions`** — `#include "webui\config\CfgFunctions.hpp"`.
   Check with `isNil "webui_fnc_init"` in the debug console; `false` is good.
3. **`description.ext`** — `#include "webui\config\CfgCommands.hpp"`.
   The page's path must match the whitelist. This is precondition one.
4. **A `JSDialog` handler** — you get this by calling `webui_fnc_init` on the
   control. This is precondition two.
5. **`webui.js` reachable from SQF.** The code default is
   `ui\html\webui.js`. If your copy is anywhere else — including the
   `<mission>\webui\` layout step 1 suggests, which is NOT the default — set
   the path in your init:

   ```sqf
   WEBUI_jsPath = "webui\ui\webui.js";   // wherever you actually put it
   ```

   Two independent paths have to agree and they are set in different places:
   this one, used by SQF's `loadFile`, and the one inside the page's stub
   (step 6), used by `A3API.RequestFile`. They point at the same file. Getting
   either wrong kills that half of the boot silently.
6. **The self-boot stub, in the `<head>` of every page.** Copy it verbatim:

```html
<script>
/* Self-boot: pull webui.js out of the PBO rather than waiting for SQF to
   inject it. A <script src> cannot work here — no resolvable base URL. */
window.WEBUIReady = new Promise(function (r) { window.__webuiReady = r; });
if (typeof A3API !== "undefined" && A3API.RequestFile) {
  window.__webuiBootPath = "stub";
  A3API.RequestFile("ui\\html\\webui.js").then(function (src) { (0, eval)(src); })
    .catch(function (e) { console.error("self-load failed", e); });
}
</script>
```

Adjust that path to match step 5. Then wait on `window.WEBUIReady` rather than
polling for `window.WEBUI`:

```js
window.WEBUIReady.then(function (WEBUI) {
  WEBUI.on("money", function (v) { render(v.cash); });
});
```

**Why this is not optional.** Without it a page has exactly one way to get the
bridge — SQF's injection, which cannot fire until the browser is ready to
receive JavaScript and has to retry until it lands. That retry is the floor on
how soon any screen can show data. With the stub the page fetches the bridge
itself the moment it parses, and the floor disappears. `ui/demo.html` and
`ui/probe.html` both carry it; a page written from the README without it works,
but populates noticeably later, and on a fast client it is the difference
between instant and most of a second.

Note the circularity if you are tempted to skip it: `WEBUI.file()` is a method
*on* `WEBUI`, so it cannot be what loads `webui.js`. `A3API.RequestFile` is the
raw engine call and is available to the page immediately.

## Verifying

Point a control at `ui/demo.html` and open it. Expect in the RPT:

```
[WEBUI] initialised (4-way) t=...
[WEBUI] mission root: mpmissions\__CUR_MP.<map>\
```

and in the page, a live bridge with working call buttons.

and, since 4-way readiness was made explicit, a line naming which signal got the
bridge up and how long it took:

```
[WEBUI] ready via 'hello' 0.205s after init (t=...)
```

`hello`, `message` or `pageloaded` inside ~0.25 s is healthy — measured range on
a working client is 0.20–0.39 s depending on which signal wins (FINDINGS 10).

`timer` is the failure: nothing reached the page for three seconds and the queue
drained on the backstop. Check step 3's whitelist, then grep the RPT for
`[WEBUI] inject: loadFile REFUSED` — `loadFile` is refused in some client
contexts and takes the whole injector down with it (FINDINGS 11), which leaves
the page's own stub from step 6 as the only working boot path.

Then:

```sqf
[] spawn webui_fnc_drawRate;
```

If it reports ~1 fps, **the game was not launched through Steam** — that is the
first thing to rule out, before anything else. See docs/FINDINGS.md.

## When you cannot read the RPT

Someone else's server, someone else's client. `webui_fnc_bootProbe` reports the
same verdict **on screen**, so a player can screenshot it and send it to you:

```sqf
[] spawn webui_fnc_bootProbe;      // arm it, then open any page
```

It needs nothing from the page and works against pages you cannot edit.

## Common failures

| symptom | cause |
|---|---|
| page renders, calls never arrive | path not in `allowedHTMLLoadURIs`, or `webui_fnc_init` never called |
| page blank | `<script src>` in the page — it cannot resolve |
| animation frozen, buttons laggy | launched outside Steam |
| a feature "does nothing" | a JS error killed the page — check the RPT for `JS ERROR` |
| `texture()` gives a broken image | bad path; it resolves with a stub instead of rejecting |
| pushes never arrive | sent before the page was up — use `webui_fnc_push`, which queues |
| page renders instantly, then sits empty for most of a second | no self-boot stub (step 6), so the bridge only arrives on SQF's retry. Run `webui_fnc_bootProbe`: boot path `sqf` confirms it |
| some players report the delay and you cannot reproduce it | the same thing. The stub always wins the race on the machine that has it, and whether `PageLoaded` is caught depends on how fast the client loads the page, so a faster machine can feel slower |
