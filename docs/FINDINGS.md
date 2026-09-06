# Measured behaviour of `CT_WEBBROWSER`

Everything here was measured in game, not inferred, and several entries replace
a confident wrong answer. Numbers come from one client — Linux, Proton
(GE-Proton10-34), Wayland, gfx1151, Arma 2.22.153995 — unless stated. The
diagnostics in `diagnostics/` reproduce all of it in about a minute.

## 1. Launch path decides whether animation works at all

**The single most expensive finding here.** Same page, same build, same machine,
thirteen minutes apart:

| launched via | idle | animated GIF | requestAnimationFrame |
|---|---|---|---|
| a launch script, outside Steam | 0.6 fps | 1.0 fps | 1.9 fps |
| **Steam** | 0.6 fps | **20.0 fps** | **61.4 fps** |

The page's user agent is `... Valve Steam Client Safari/537.36`: under Proton
this control is serviced by Steam's webhelper, and frame delivery only runs when
the Steam overlay hook (`gameoverlayrenderer.so`) is injected — which happens
when the game is started from Steam.

Idle sitting at ~0.6 fps in both cases is correct and desirable: delivery is
**dirty-driven**, so a static screen costs nothing and only animating regions
pay for themselves.

**If a page looks frozen, or its buttons feel laggy, check how the game was
launched before touching a line of CSS.** `webui_fnc_drawRate` tells the two
worlds apart in fifteen seconds.

Conclusions that were reached against the clamped client and are simply false
for a normally launched game: "CSS transitions cannot render", "rAF is throttled
to ~2 fps", "a 60 Hz JS mutation cannot force a repaint", "no engine-side lever
changes it" (`ctrlSetFocus`, `EachFrame ctrlCommit`, `EachFrame displayUpdate`
and 30 Hz `ExecJS` were all measured on the clamped client).

**`EachFrame displayUpdate` was never actually measured either.** `displayUpdate`
only drives a *UI-on-texture* display; a browser control hosted the way this
library documents it -- inside a dialog's `class controls`, or an RscTitles
overlay -- has an ordinary parent display, so the pump issued a draw request
against nothing and the phase resampled an idle control. `webui_fnc_forceProbe`
now reports that phase as NOT APPLICABLE rather than printing a baseline as a
result. Inside a ui2texture host it is the whole mechanism — measured in **§12**: one
browser paint per game frame, driven by nothing but this call.

**`EachFrame ctrlCommit` was never actually measured**, on either client. That
phase of `webui_fnc_forceProbe` read its arguments off `_this`, but `EachFrame`
carries no event data and passes its args in `_thisArgs`, so the handler threw
at its first statement every frame and the control was never marked dirty. The
phase sampled an untouched control and its baseline was recorded as a negative
result for the lever. Fixed 2026-08-29; the phase has not been re-run, so this
lever is currently **unmeasured, not disproven** -- do not cite it either way
until a fresh forceProbe run says otherwise.

## 2. Typed text DOES reach the DOM

Real `<input>`, `<textarea>` and `contenteditable` all work. Typing 25
characters produced `keydown` 25, `keypress` 25, `beforeinput` 25, `input` 25,
and `.value` held the string. `contenteditable` behaves identically. Backspace
registers.

This entry previously said the opposite, on the strength of a probe tile that
printed `keydown: 0` as **static text with no listeners attached** — it could
never have shown anything else. If you inherit a codebase that avoids `<input>`
in pages, this is likely why.

`webui_fnc_prompt` is therefore optional, not mandatory.

## 3. The browser costs no measurable frame rate

A/B/A with one sampling method — closed, open, closed again:

```
baseline, no browser : 56.0 fps
browser open, idle   : 57.1 fps
closed again         : 58.1 fps
```

−1.1 fps, well inside a ~13 fps min/max spread. An earlier "~12 FPS cost" was
never an A/B: the with-browser half was sampled immediately after a dialog
opened while the page was still loading, and the baseline half had no recorded
provenance. `webui_fnc_bench` runs the honest version.

## 4. Viewport scales with the CONTROL, not the screen

| control (UI_GRID) | CSS viewport | px per grid unit |
|---|---|---|
| 40 x 20 | 1200 x 600 | 30 |
| 19 x 9 | 570 x 270 | 30 |

**30 CSS pixels per UI_GRID unit at devicePixelRatio 1, regardless of screen
resolution.** So the same control gives the same CSS surface on 1080p and on
ultrawide — but the viewport is *not* a fixed 1200x600, which is what measuring
a single control and generalising will tell you.

It matters: a `1rem = width / 75` scheme gives 16px on a 40x20 box and 7.6px on
a 19x9 panel.

## 5. Latency, per leg, and a superseded number

This section used to report a lone figure of `618 ms at 1 KB against 701 ms
at 3.8 MB` for ExecJS, while API.md quoted `WEBUI.call` at `~15-21 ms`.
Those cannot both be true, because `call()` contains an ExecJS leg. Neither
number had a probe behind it. Both are superseded by
`webui_fnc_latencyProbe`, which measures each leg separately, on both
clocks, and prints the poll-vs-event difference as its own row so the same
mistake cannot be made silently again.

The probe reports, per payload rung (1 KB / 64 KB / 512 KB / 4 MB), min /
median / max over 20+ iterations:

> **Two caveats on the numbers below, both found 2026-08-29.**
>
> 1. The `med=` figures were produced with an **upper**-median estimator
>    (`sorted select floor(n/2)`), which on these n=20 runs is the 11th smallest
>    rather than the midpoint of the 10th and 11th. The probe computes a true
>    median now, so a fresh run reports slightly lower medians. Min and max are
>    unaffected.
>
> 2. Every sample is a difference of two `diag_tickTime` reads, and that command
>    is **single precision** — the BIKI states "the more time has past since
>    restart the less precise the returned value will be". The step is
>    ~0.24 ms after an hour of uptime, ~7.8 ms after a day, ~62 ms after a week.
>    The uptime when these rows were captured was not recorded, so their true
>    resolution is unknown; rows quoted to 0.1 ms may be quantisation. The probe
>    now prints the live quantum before every run, warns above 1 ms, and reports
>    a **bracketed mean** per leg and rung, whose error is one quantum divided by
>    the iteration count. **Re-measure on a freshly started client before
>    quoting these medians as fact.**


| leg | direction | clock | what it includes |
|---|---|---|---|
| `execjs-echo` | SQF to page to SQF | `diag_tickTime`, event-stamped | transport only; the reply stamp is written inside the JSDialog event handler, no polling |
| `execjs-oneway` | SQF to page | derived | a bound (at most the echo min) plus echo/2 labelled "symmetry assumed"; the two clocks share no epoch, so one-way cannot be measured directly |
| `fnc-call` | SQF to page to SQF | `diag_tickTime`, poll return | what `webui_fnc_call` really costs, polling wait included; minus `execjs-echo` at the same size = scheduler + reply-path overhead |
| `page-call` | page to SQF to page | `performance.now()` | what API.md quotes; the SQF reply rides ExecJS, so the big rungs load the same path the old 618/701 ms claim measured |
| `page-ask` | page to SQF | `performance.now()` | bool-only, no ExecJS reply leg; checks the old "roughly half of call()" claim |

Measured 2026-08-14, healthy client (clamp verdict `healthy`, forced rate
53.7 fps), Steam launch, in-mission on a ~200-entity server:

```
[WEBUI-LAT] leg=execjs-echo size=1024    side=sqf-event n=20 min=7.8ms  med=11.7ms max=13.7ms
[WEBUI-LAT] leg=execjs-echo size=65536   side=sqf-event n=20 min=7.8ms  med=11.7ms max=13.7ms
[WEBUI-LAT] leg=execjs-echo size=524288  side=sqf-event n=20 min=9.8ms  med=11.7ms max=27.3ms
[WEBUI-LAT] leg=execjs-echo size=4194304 side=sqf-event n=20 min=60.5ms med=68.4ms max=91.8ms
[WEBUI-LAT] leg=fnc-call    size=1024    side=sqf-poll  n=20 min=11.7ms med=13.7ms max=15.6ms
[WEBUI-LAT] leg=fnc-call    size=65536   FAIL (timeout)
[WEBUI-LAT] leg=fnc-call    size=524288  FAIL (timeout)
[WEBUI-LAT] leg=fnc-call    size=4194304 FAIL (timeout)
[WEBUI-LAT] leg=page-call   size=1024    side=page      n=20 min=14.7ms med=21.0ms max=23.9ms
[WEBUI-LAT] leg=page-call   size=65536   side=page      n=20 min=14.8ms med=17.5ms max=44.2ms
[WEBUI-LAT] leg=page-call   size=524288  side=page      n=20 min=33.6ms med=46.3ms max=91.0ms
[WEBUI-LAT] leg=page-call   size=4194304 side=page      n=20 min=219.3ms med=280.5ms max=365.6ms
[WEBUI-LAT] leg=page-ask    size=0       side=page      n=20 min=10.8ms med=14.5ms max=34.2ms
```

(The fnc-call FAIL rows are not a latency result. See the truncation finding
below.)

What the run established:

- Transport round trip is ~12 ms and flat to 512 KB. The execjs-echo medians
  are identical at 1 KB, 64 KB and 512 KB, so fixed cost dominates; bytes
  only start to matter by 4 MB (~68 ms).
- The historical 618/701 ms did not reproduce. The worst median anywhere in
  the matrix is 280 ms, at 4 MB on page-call. Whatever produced the old
  number (an earlier engine build, a loaded frame schedule, or measuring
  through a sleeping poll), it is not a property of the current bridge.
- The polling wait inside `webui_fnc_call` costs about 2 ms at 1 KB
  (13.7 vs 11.7 median), not hundreds.
- API.md's old ~15-21 ms was real. It matches page-call at 1 KB (median
  21.0 ms). The two "contradictory" numbers were simply different legs;
  both docs now say which leg they mean.
- `ask` lands at 14.5 ms median, about 0.7x `call`, not the half API.md
  used to claim. Corrected there.
- fnc-call at 64 KB and up fails for a reason that has nothing to do with
  latency. The RPT shows the page's reply arriving as
  `["REPLY",21,true,"xxx...` (valid JSON cut off mid-string): the engine
  truncates the JSDialog message, page to SQF direction only. The reverse
  direction has no such limit; execjs-echo carried 4 MB in the same
  session, and page-call's big rungs returned through ExecJS intact. Big
  payloads therefore flow SQF to page freely, while page to SQF messages
  must stay under the cap or be chunked.

`webui_fnc_msgCapProbe` bisected the cap to the character (2026-08-14, same
client):

```
[WEBUI-CAP] chan=alert VERDICT: max intact message = 10240 chars (ASCII; 10241 truncated, both retested 3x)
[WEBUI-CAP] chan=ask   VERDICT: max intact message = 10240 chars (ASCII; 10241 truncated, both retested 3x)
```

The cap is exactly 10 KiB (10240 characters), identical for `SendAlert` and
`SendConfirm`, so it looks like one shared engine buffer rather than a
per-API quirk. The boundary held 3/3 on both sides of the fence. The whole
JSON envelope counts against it (verb, seq, name, args, quoting), so treat
~10 KB as the page-to-SQF payload ceiling and keep margin. `webui.js`
enforces it: an oversized `call()` or `ask()` rejects immediately with the
size in the message, and an oversized `_invoke` reply is replaced by a
named error that fits. Without the guard the engine truncates mid-JSON and
the failure presents as a timeout with no cause, which is how this cap went
unnoticed in the first place. Measured with ASCII payloads; whether the
engine counts UTF-16 units or bytes above U+007F is untested, so non-ASCII
payloads should assume the worst case, bytes.

What the original ladder verified still stands: every rung from 1 KB to
3.8 MB arrived intact in the SQF to page direction, and the probe
re-verifies this by failing a rung loudly rather than assuming it. Shipping
an asset from the server to a page at runtime therefore remains viable:
remoteExec the bytes, push them in as a data URI, no client repack.

`Deflate` manages 329:1 and 381:1 on repetitive text, useful for the network
leg even though ExecJS plainly does not need it.

## 6. RequestTexture searches the GAME filesystem

A mission-relative path resolves to nothing — and it does **not** reject. It
logs `Unknown sampler texture type` and **resolves with a ~23 character stub**,
which reads as success and will happily be assigned to `img.src`.

```
mission-relative    : FAIL   23 chars
mission root + rel  : OK   2007 chars
a3 addon path       : OK   5463 chars
```

`WEBUI.texture()` retries under `getMissionPath ""` and keeps the bare path for
real addon paths, so callers can ignore this.

## 7. Audio works, and ignores the game's volume sliders

Audible, `AudioContext` at 48 kHz. **No in-game volume slider affects it** — it
plays through the OS mixer. A muted player still hears the page.

Also gesture-gated: an SQF-driven `play()` fails with `NotAllowedError` and the
context sits `suspended`, because there was no user gesture. A click unlocks it.

`webui_fnc_volumeSlave` pushes the volumes so the page can multiply its own gain
by them, with distance riding the same channel.

**It does not read `musicVolume` / `soundVolume` / `radioVolume` for that, and a
version of it that did never worked.** Those three return the *scripted fade*
coefficient — the BIKI is explicit, "Returns the current music volume (set by
`fadeMusic`)" — so they sit at 1 no matter where the player drags the Audio
Options sliders. The profile sliders come from `getAudioOptionVolumes`
(`[effects, music, radio, von, UI, map]`, Arma 3 1.94). What the player actually
hears is the product of the two, which `fadeMusic`'s own page states: **Final
Volume = Client Setting × Scripted Volume**. That product is what the `vol`
channel now carries.

Nothing could have caught this from the outside: the wrong getters return a
perfectly plausible `1.0`, so the page rendered fine and simply never responded
to the slider. Found 2026-08-29 by checking the getters against their own
documentation rather than against their names.

Streaming is not possible: the sandbox permits media inline or via `data:` only,
so `<audio src="http://...">` is blocked exactly like `fetch`.

## 8. Other measured facts

- **Four browser controls run simultaneously**, each with its own channel.
- **CEF is in-process** — zero child processes, thread count flat. Client RSS
  moved tens of MB across a run that included 4 MB payload pushes, not hundreds.
- **Pages can be transparent over the world.** A control with
  `colorBackground[] = {0,0,0,0}` and a page painting `background: transparent`
  shows the game behind it, so HUD-style overlays are possible.
- **Pages are handed to the browser as a `blob:` URL**, not a path. There is no
  URL cache to bust; a rebuilt page is picked up on the next open.
- **`OpenDevConsole` needs the `-debug` start parameter**, and silently does
  nothing without it.

## 9. Serving pages from the server, and what blocks it

A page has to load from a path in `allowedHTMLLoadURIs`, which means the mission
PBO, which means shipping one line of HTML costs every connected client a full
mission re-download. `webui_fnc_serve` works around that: the PBO page still
loads and renders, and the server then overrides its markup in place. If the
server is silent the PBO page stands, so the fallback is the absence of a reply
rather than a code path that has to run.

Three things were measured on a dedicated Linux server (Arma 2.22.154020,
2026-08-18) while building it:

- **`ctrlWebBrowserAction "Deflate"` works server-side, with no display and no
  browser control.** The BIKI says it works with `controlNull`; it was not
  obvious that held on a headless dedicated server with no CEF anywhere, and it
  does. A round trip through `Deflate` then `Inflate` returned the input exactly.
  This matters because the server->client hop is the only size-constrained leg in
  the chain, and real pages deflate about 3.6x (a 218 KB page to 59 KB).
  `Inflate` caps its OUTPUT at 1 MB, so pages must stay under that.

- **`loadFile` is a disabled command on a dedicated server.** The engine answers
  `Trying to execute a disabled command 'loadfile' (1 arg)` and the calling
  script dies at that line -- not a return of `""`, an abort. So the server
  cannot read a page out of its own addon that way, and the obvious
  implementation of this feature ships inert. `preprocessFile` is not the
  substitute either: it is a C preprocessor, and it eats `//` inside inline
  JavaScript. Reading the bytes through an extension is the way out, and reading
  them off disk is better than an addon anyway -- no repack to ship a change.

- **Replacement must be `document.open()/write()/close()`, not `innerHTML`.**
  Scripts inserted via `innerHTML` never execute, so the page would render
  correctly and do nothing -- a failure that looks like success. `document.write`
  runs them, and because the frame is never renavigated the window object
  survives, so the `A3API` binding from the original whitelisted load is still
  there for the incoming document.

Not yet measured: whether a page loaded with `OpenDataAsURL` gets the `A3API`
binding at all. The wiki says the API "is injected into every local content
page", which suggests yes, and if it holds it removes the need for a PBO
baseline entirely. Until someone checks, the override approach above is the one
that cannot lose the bridge.

## 10. The bridge's arrival is a race, and section 1's client always won it

**MEASURED 2026-08-28** (see the results block at the end of this section; the
analysis below was written before them and one of its predictions was wrong).
Originally filed as: Every other entry in this file is a number off a probe. This
one is read out of the source and the engine's own documentation, and it is
here because it corrects a claim that used to be stated as measured fact. Treat
it as a hypothesis with a strong paper trail until `webui_fnc_bootProbe` has
been run on a client that shows the symptom.

`webui_fnc_init` used to carry this comment: *"PageLoaded does NOT fire when the
page came from the control's url= attribute"*, and the whole readiness design
was built on it. The wiki says otherwise — `PageLoaded` *"Fires when the current
page has finished loading... This fires multiple times, when the current page
(URL) was changed or when the browser is Resumed."* No exemption for `url=`.

What is actually true is narrower and worse: the handler is attached inside
`webui_fnc_init`, which runs from the dialog's `onLoad`, which runs **after** the
browser began loading `url=`. If the page finishes loading first, the event
fires into a control with no handler on it and is missed. That is a race, and it
resolves against **fast** clients — a quick page load is exactly what makes the
event beat the handler.

The consequence is that everything queued by `webui_fnc_exec` — `_setRoot`, any
server-side markup override, and every push the mission sends on open — waits
for whichever readiness signal does land. The remaining paths were:

- the page's own self-boot stub, which was in both shipped pages but **named
  nowhere in README.md or INSTALL.md**, so anyone installing from the docs did
  not have it (and the docs pointed at `WEBUI.file()`, which cannot load the
  file that defines `WEBUI.file()`);
- SQF's injector, which fired three times **0.3 s apart**, with the first shot
  landing before the page could receive it — so the effective floor for a page
  without the stub was 0.3–0.6 s plus a round trip;
- a 3 s backstop timer.

So the predicted symptom for a docs-following install is: page renders
instantly, sits empty for something under a second, then populates — on every
open of every screen. Invisible to anyone whose pages carry the stub, because
for them the stub wins every time.

Fixed by making the injector fire immediately and retry on a 50 ms backoff that
stops the moment the bridge answers, and by having the injected statement
announce itself (`HELLO`) instead of waiting for the page's own code to call
something. Readiness now records which signal won and how late, and
`webui_fnc_bootProbe` puts that on screen for cases where the RPT belongs to
someone else.

The general lesson is the one worth keeping: **a negative observation about an
asynchronous event is a claim about when you attached your listener, not about
the event.** "I never saw it fire" and "it does not fire" differ by a race, and
that race can resolve the other way on hardware you do not own.

### What the in-game run actually showed (2026-08-28, Arma 2.22, Malden, dev server)

Four page opens on one client, with the reworked injector:

| page | stub? | ready signal | init -> ready | injector |
|---|---|---|---|---|
| LANDING | yes | `message` | 0.394 s | **died before its first log line** |
| HUDWEB | yes | `timer` | **3.022 s** | **died before its first log line** |
| bridge harness | no | `hello` | 0.205 s | ran, 13421 B, 3 attempts |
| bridge harness | no | `hello` | 0.200 s | ran, 13421 B, 3 attempts |

Confirmed: the injector path works and is the readiness signal on a stub-less
page, reproducibly, at ~0.20 s.

**Refuted: the predicted ~50 ms floor.** It took three attempts over 0.315 s —
the first two shots were dropped because the page was not yet able to receive
them. The retry loop helps (against a 0.3–0.6 s floor for the old three-shot
ladder) but the honest improvement is roughly **1.5–2x, not the 6x predicted**.
Do not quote 50 ms; the receptiveness of the page, not the retry interval, is
the binding constraint.

**And the real finding, which was not the ladder at all:** see section 11.

## 11. `loadFile` is refused on CLIENTS too, and a refusal ABORTS the script

Section 9 recorded `loadFile` as a disabled command *on a dedicated server*. An
in-game client RPT shows the same refusal, once per page open:

```
Trying to execute a disabled command 'loadfile' (1 arg)
```

This matters far more than it looks, because a refusal is **not** a return of
`""` — it aborts the calling script at that line. Both SQF-side paths that
deliver `webui.js` call `loadFile`, so when the refusal lands the injector dies
*before its first log statement*, leaving no trace at all. That is exactly the
signature on the two opens above with no `inject:` line, and it is why one of
them fell all the way to the 3 s backstop.

Three things were then measured directly, by logging immediately *before* each
call (2026-08-28, b0788, three page opens):

- **The refusal is NOT catchable.** A `try/catch` around both calls fired
  **zero times** across five refusals. It is not an exception; it is thread
  death. Do not wrap it and assume you have handled it — the absence of a catch
  log reads as success and means the opposite.
- **The unscheduled copy is refused every time.** The `loadFile` inside the
  `PageLoaded` handler returned a byte count **0 of 3** opens. The scheduled
  copy inside `spawn` succeeded on 1 of 3.
- **Which destroyed an entire readiness signal, silently.** Because that
  `loadFile` was the FIRST statement in `_markReady` and `PageLoaded` passes
  `_reinject = true`, the handler aborted before it could mark readiness or
  drain the queue. Across **seven measured opens on two builds, `pageloaded`
  never once won the race** — not because the event does not fire, but because
  its handler killed itself at its own first line.

**That is the true origin of section 10's founding belief.** This file used to
record "PageLoaded does NOT fire when the page came from the control's `url=`
attribute" as engine behaviour, and the whole readiness design was built around
routing past it. The event fires exactly as the wiki documents. The handler
aborted. Reordering `_markReady` so the re-injection happens LAST — after the
mark, the drain and the clamp check — costs nothing and restores the signal,
because an abort at the end of a function loses only what is left to do.

**Confirmed by the reverse case, 2026-08-29.** On a deck page open, the RPT
shows `inject: loadFile` with no `webui.js N bytes` line after it -- SQF's
injector died at the refusal and delivered nothing -- and the bridge still came
up, readiness landed via `pageloaded` in 0.231s, and all eleven self-test checks
passed. (The suite was eleven checks on that date; it is thirteen now — a "refused
prompt leaves the running prompt's field alone" check was added when
`fn_prompt`'s busy guard turned out to be seeding the overlay before refusing,
and a "stale busy latch is cleared, not obeyed" check when the busy latch turned
out to survive across missions.) The page's own `A3API.RequestFile` stub carried the whole boot on its
own. That is the architecture working as intended: the reliable path does not
touch `loadFile`, and the unreliable one is a net.

**The practical consequence:** SQF injection cannot be relied on as the primary
boot path. The page's own `A3API.RequestFile` stub does not use `loadFile` and
is the only path that always works — which is why INSTALL.md step 6 is
mandatory rather than an optimisation, and why the injector should be treated
as a net, not a mechanism.

## 12. A browser inside a UI-on-texture display paints at frame rate

**Measured 2026-09-06, Arma 2.22.154049, launched through Steam** (so §1's
healthy world), on a `C_Hatchback_01_F` with one hidden selection.

The engine can render a *display* into a texture and hand that texture to
`setObjectTexture` — the "UI On Texture" procedural source, 2.12/2.14
(`Procedural Textures` on the wiki). Put a `CT_WEBBROWSER` in that display and
the page is on the model. BI's own `CT_WEBBROWSER` page describes the
combination ("inside a ui2texture containing a browser…"); nobody had reported
running it. It runs:

```sqf
_veh setObjectTexture [0, "#(rgb,1024,1024,1)uiEx(display:webui_uiTexDemo,uniqueName:demo_4_88,bgColor:#000000ff)"];
addMissionEventHandler ["EachFrame", { displayUpdate (findDisplay "demo_4_88") }];
```

| event | frame | delta |
|---|---|---|
| string applied | 8645 | — |
| ui2texture display exists (`findDisplay` non-null) | 8645 | 0 |
| browser `Draw` #1 | 8699 | +54 |
| browser `Draw` #60 | 8758 | +59 |
| browser `Draw` #600 | 9298 | +540 |

600 paints in 653 frames, the first 54 being page load: **one Chromium paint per
game frame** once the page is up. An animated canvas on the car runs at the
game's rate. `examples/ui2texture/` is the exact probe.

What the run pinned down, beyond "it works":

- **The display is created by the first texture draw, not by script.**
  `findDisplay "<uniquename>"` is null until the engine has needed the texture
  once. Poll for it (an `EachFrame` that tolerates null does); do not wait on
  it synchronously. Unique names are forced lowercase.
- **Without `displayUpdate` it renders once and freezes.** The pump *is* the
  feature. Stop the pump and the last frame stays — which is how a static sign
  can be rendered once and cost nothing after.
- **Preload the display once or the first use fails** with "Cannot load
  mipmap" (feedback T171035 / T170766). `createDisplay` then `closeDisplay 1`,
  once per session, before the first string is applied. Lifted from Advanced
  Equipment's shipped code, which ships ui2texture on every laptop.
- **The engine drops the display when nothing references it.** After
  `setObjectTexture [i, "#reset"]` (2.20+), `findDisplay` was already null.
  Cleanup is free; do not hold a handle across a reset.
- **`setObjectTexture` is local; `…Global` broadcasts the string.** Every
  client then instantiates its own display and its own browser. A probe should
  stay local. A shipped feature going global must budget one Chromium per
  client per live surface, and every client needs the display class and the
  page (both come with the mission).
- **The display is rendered in its own 0..1 space, square.** Author the
  display with `x=0;y=0;w=1;h=1`, not safezone — safezone maths pushes the
  page off the texture. `uiEx` renders 1:1 regardless of texture shape
  (feedback T170754, secondary source), so a 1024×2048 texture squashes the
  page; use `viewportW/H` or design for the stretch.
- **Only classes with `hiddenSelections` take it.** `getObjectTextures obj`
  returning `[]` means never. In particular `createSimpleObject [<p3d path>,…]`
  objects "cannot be textured" and "addAction does not work" on them (wiki,
  `createSimpleObject`); the class-name syntax can be textured.

### Cost at scale (measured 2026-09-06)

`AP_fnc_uiTexBench` in the host mission: N class-name simple cars in a grid, each
wearing a 512² white-noise page through its own ui2texture display and browser,
every display pumped every frame, `diag_fps` sampled before/during/after. Steam
launch, Proton, one client. Frame time from the post-run baseline:

| cars | idle ms | loaded ms | Δ ms | Δ per car |
|---|---|---|---|---|
| 20 | 13.9 | 19.0 | 5.1 | **0.26 ms** |
| 60 | 13.2 | 33.1 | 19.8 | **0.33 ms** |
| 160 | 13.5 | 32.8 | 19.3 | 0.12 ms |
| 200 | 12.3 | 30.7 | 18.4 | 0.09 ms |

Two facts. In the linear region a live HTML texture costs about **a quarter to a
third of a millisecond of frame time per surface** — ten in view is ~3 ms, 75 → ~62
fps. From roughly sixty surfaces up the loaded rate **pins at ~30 fps regardless of
N**: 60, 160 and 200 all land within 2 fps of each other. That is a throttle
somewhere between the browsers and the readback, not a cheap tail — the per-car
figure falls because the ceiling stopped moving, and each browser is presumably
painting less often. All N displays reported live in every run. Memory per
instance was not measured.

### Clothing, JIP, and the registration race (measured 2026-09-06)

**Uniforms and backpacks take it; vests, headgear and goggles cannot.** A texture goes
on a hidden selection, and on a person the vanilla models carry one on the uniform
(selection 0) and on the backpack (its own object). Nothing else on the body has one,
and no command retextures a vest (the wiki's own note). `examples/ui2texture/fn_wearPage.sqf`
paints uniform + backpack from one display -- one browser per viewer for both. The
uniform's UV sheet is a patchwork, so an unaware page is chopped across the body.
Changing uniform, respawning or opening the Arsenal resets the texture; re-apply where
your clothing skins already re-apply.

**The string is global and JIP-safe; the pump is per viewer.** `setObjectTextureGlobal`
with a `uiEx(...)` string replicates like any texture and the engine keeps it for late
joiners. Every client that draws the object then owns a display and a browser -- and
nothing in the string can call `displayUpdate` on them. So an ANIMATED surface needs
a per-viewer half: `remoteExec` a registration (`jip = 1`, one key per object) into a
manager that pumps it. A STATIC surface needs a per-viewer serve once and no pump at all.

**The display is created by the first draw, seconds after the string is applied.** The
first manager pruned any registration whose `findDisplay` was null -- which is every
registration, for at least a frame and typically a second -- so no surface was ever
pumped and each froze on its black first frame. The symptom was "just black, no
animation" with a clean log: texture applied, registered, `UI2Tex creating new display`
one second later. Prune on a null OBJECT only; treat a missing display as "not drawn
yet" and pump it the frame it exists. Same rule for a freeze: gate it on TIME after the
first paint, never on a paint count -- a static page paints once or twice and a count
of thirty never arrives.

### ExecJS does not execute inside a ui2texture browser (measured 2026-09-06)

The one-directional surprise. Page -> SQF works in a browser that lives inside a
UI-on-texture display: `SendAlert`, the bridge's `call`/`log`, `RequestTexture`,
`RequestFile` all answered. SQF -> page does not: `ctrlWebBrowserAction ["ExecJS", …]`
-- and therefore `webui_fnc_push`, `webui_fnc_call` and `webui_fnc_serve`'s
`WEBUI._serve` -- never ran, with no error and the exec queue reporting "drained".
The identical serve swap works offline in Chrome (`examples/ui2texture/serve_swap.mjs`),
and the "bridge proven via hello" line still appears in-texture because the page's own
`webui.js` self-boot never needed ExecJS.

What still reaches an in-texture page from the engine: **`ctrlWebBrowserAction
["OpenDataAsURL", markup]`**. It loads a whole document with no script in the path,
the loaded document keeps `A3API` (its `RequestTexture` returned the 1024-px base
sheet on the same run), and its inline scripts run. That is how a server-streamed
skin is applied now (`fn_htmlSkinClient`): fetch through the serve fetcher, hand the
bytes to the control. Design in-texture pages as self-driving -- state in through the
initial markup, `RequestFile`, `RequestTexture`; nothing pushed later. (This is also
why the parallax probe's camera vector never arrived.)

### Server-streamed static skins (measured 2026-09-06)

The art never enters the mission PBO. `fn_htmlSkin` broadcasts
`uiEx(display:webui_uiTexSkin,uniqueName:apskin_<id>)`; the display's own page is a
black placeholder that boots `webui.js`; on each viewer `fn_htmlSkinClient` waits for
the display, `webui_fnc_init`s its browser, and `webui_fnc_serve`s `skins/<id>.html`
from the server -- a 512 px JPEG data URI over the document, ~55 KB, ~75 KB as a page.
Then it paints once, freezes and stops the browser.

Measured: first paint **2 s after apply**; the display reported alive every minute for
the length of the test; **the paint survived leaving and returning** at 500 m / 30 s and
across the map / 3 min. One display per SKIN, so every object wearing it shares one
browser per viewer. Deflate on the wire makes a base64 JPEG *larger* (74 625 -> 75 296
bytes); ship these raw. Getting the image out of a `.paa` is a tool job; the page maker
takes PNG/JPEG.

### Two detours worth not repeating

- **Do not inflate a copy of the model to make a texture "float".** A scaled
  class-name simple copy does float (`getObjectScale` read 1.1; `boundingBoxReal` does
  NOT move with render scale and was the wrong meter), but a second body chasing the
  first fights the vehicle in motion, and `damagehide` -- a selection name that looks
  like wreck detail -- holds a BI car's entire undamaged body: hide it and the shell is
  invisible with every log line green. What "3D from HTML" can be on a flat selection is
  view-dependent parallax from a camera vector the page is pushed each frame.
- **Name a texture source the way `BIS_fnc_initVehicle` reads it.** A bare string is a
  VARIANT class; it returned `true` and changed nothing. `["Red", 1]` is a texture source.

Two routes were researched but not spiked, for when a live Chromium per
surface is too much: the 2.22 **extension texture source**
(`#(rgb,w,h,1)extension("name","unique",0)` → `RVExtensionFillTextureSource`
fills a CPU buffer on a texture-loading thread; pixel format codes are still a
TODO on the wiki), and rendering the page once to a canvas, shipping the PNG
through the bridge to an extension that writes a file, and pointing
`setObjectTexture` at the absolute path (documented to work; unique filenames,
because the engine caches by path).
