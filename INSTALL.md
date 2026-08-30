# Install checklist

Six things. Miss **step 3 or step 4** and it fails **silently** — the page
renders perfectly and simply cannot talk to the game. (Step 2 fails loudly; it
has its own check below.) Miss the sixth and it works, but every screen takes a
visible moment to populate.

1. **Files** — `functions/`, `diagnostics/` and `ui/webui.js` into the mission,
   plus `ui/demo.html` and `ui/probe.html` if you want the verification page in
   step "Verifying" below. Put the pages where the whitelist in step 3 expects
   them — `<mission>\ui\html\` unless you change the pattern.
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

Point a control at `ui\html\demo.html` and open it — the whitelist in step 3
covers `ui\html\*`, so a control pointed at a bare `ui\demo.html` reproduces
precondition one instead of ruling it out. Expect in the RPT:

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

`timer` is the failure: nothing reached the page for three seconds. The queue is
**held, not drained** -- nothing has been lost, but nothing will arrive until the
bridge actually announces itself. Check step 3's whitelist, then grep the RPT for
`[WEBUI] inject: loadFile` and look at **whether an `inject: webui.js N bytes`
line follows it**. A missing follow-up means the refusal killed the injector:
`loadFile` is refused in some client contexts, the refusal is not catchable and
prints nothing of its own (FINDINGS 11), so the absence of the second line is
the entire signal. That leaves the page's own stub from step 6 as the only
working boot path.

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

## "The page is slow to appear" — triage in order

**Read one line from the RPT first:** `[WEBUI] ready via '<signal>' Ns after init`.

| signal | meaning | what to do |
|---|---|---|
| `hello` or `message`, 0.20–0.39 s | healthy | nothing |
| `pageloaded` | the document loaded but the bridge had not announced itself yet | the queue is **held**, not drained, until a real `hello` arrives. Usually fine; if it persists, the stub path is broken |
| `timer` | nothing reached the page for three seconds; the queue is HELD, not lost | step 3's whitelist, then the step-6 stub, then `WEBUI_jsPath` |
| no line at all | `webui_fnc_init` never ran on the control | your `onLoad` |

Then, in order of how much time they cost:

1. **The whole page never populates.** Path not whitelisted, or `init` never
   called. Unbounded, and silent. `webui_fnc_bootProbe` names which.
2. **3 s backstop.** No stub and a refused `loadFile`. The tell is an
   `inject: loadFile` line with no `inject: webui.js N bytes` line after it —
   the refusal is not catchable and kills the injector silently.
3. **A slow `ask` handler freezes the page.** `WEBUI.ask` runs its SQF handler
   *unscheduled* while the page is blocked inside `SendConfirm`, so the whole
   document stops for as long as it runs. Anything over 5 ms logs
   `[WEBUI] SLOW ask(...)`. Move expensive work to `webui_fnc_on` + `WEBUI.call`,
   which is spawned.
4. **A `WEBUI.call` to a handler that never answers** costs its full timeout
   (10 s default). An *unregistered* name fails immediately, so a 10 s wait
   means a registered handler that never returned.
5. **Oversized replies.** Over 10240 bytes page→SQF is truncated silently;
   `webui.js` now refuses to send one and names it instead of letting it present
   as a timeout.
6. **Page code gated behind `WEBUIReady`.** Anything that needs nothing from SQF
   — layout, static text, listeners — should run outside that callback, or it
   waits for the entire boot.
7. **`webui_fnc_serve`** adds up to its fetch timeout (5 s default) and then
   rewrites the document, which is a visible re-render after the page was
   already up.

**If it renders but looks frozen, that is not a loading problem.** Launch path
(FINDINGS 1) first, then Steam's *GPU-accelerated web rendering* setting — with
that on, the in-game surface can sit at ~1 fps while the game itself is fine.
Delivery is dirty-driven, so a static page idling at ~0.6 fps is correct.

**Once per session**, `webui_fnc_clampCheck` forces a 60 Hz style mutation for
3 s, starting 2 s after the first page becomes ready, to tell a clamped client
from a healthy one. It briefly outlines `document.body` and restores whatever
was there before. Opt out with
`missionNamespace setVariable ["webui_clampCheckDisabled", true]` before the
first `webui_fnc_init`.
