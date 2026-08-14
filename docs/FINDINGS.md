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

## 5. Latency, per leg — and a superseded number

This section previously reported a lone figure — `618 ms at 1 KB against
701 ms at 3.8 MB` for ExecJS — while API.md simultaneously quoted
`WEBUI.call` at `~15-21 ms`. Those cannot both be true: `call()` *contains*
an ExecJS leg. Neither number had a probe behind it, and the most likely
resolution is that they measured different things — one the transport, the
other the transport **plus a scheduled-SQF polling wait**, whose granularity
belongs to the SQF scheduler, not the bridge. Both old numbers are
**superseded** by `webui_fnc_latencyProbe`, which measures each leg
separately, on both clocks, and prints the poll-vs-event difference as its
own row so that mistake cannot be made silently again.

The probe reports, per payload rung (1 KB / 64 KB / 512 KB / 4 MB), min /
median / max over 20+ iterations:

| leg | direction | clock | what it includes |
|---|---|---|---|
| `execjs-echo` | SQF → page → SQF | `diag_tickTime`, event-stamped | transport only — the reply stamp is written inside the JSDialog event handler, no polling |
| `execjs-oneway` | SQF → page | derived | a **bound** (≤ echo min) plus echo/2 explicitly labelled "symmetry assumed" — the two clocks share no epoch, so a one-way figure cannot be measured directly |
| `fnc-call` | SQF → page → SQF | `diag_tickTime`, poll return | what `webui_fnc_call` really costs, its polling wait included; minus `execjs-echo` at the same size = scheduler + reply-path overhead |
| `page-call` | page → SQF → page | `performance.now()` | what API.md quotes; the SQF reply rides ExecJS, so the big rungs load the same path the old 618/701 ms claim measured |
| `page-ask` | page → SQF | `performance.now()` | bool-only, no ExecJS reply leg; checks the "roughly half of call()" claim |

Measured 2026-08-14, healthy client (clamp verdict `healthy`, forced rate
53.7 fps), Steam launch, in-mission on a ~200-entity server:

```
[WEBUI-LAT] leg=execjs-echo size=1024    side=sqf-event n=20 min=7.8ms  med=11.7ms max=13.7ms
[WEBUI-LAT] leg=execjs-echo size=65536   side=sqf-event n=20 min=7.8ms  med=11.7ms max=13.7ms
[WEBUI-LAT] leg=execjs-echo size=524288  side=sqf-event n=20 min=9.8ms  med=11.7ms max=27.3ms
[WEBUI-LAT] leg=execjs-echo size=4194304 side=sqf-event n=20 min=60.5ms med=68.4ms max=91.8ms
[WEBUI-LAT] leg=fnc-call    size=1024    side=sqf-poll  n=20 min=11.7ms med=13.7ms max=15.6ms
[WEBUI-LAT] leg=fnc-call    size=65536   FAIL (timeout)   ← see below: NOT latency, TRUNCATION
[WEBUI-LAT] leg=fnc-call    size=524288  FAIL (timeout)
[WEBUI-LAT] leg=fnc-call    size=4194304 FAIL (timeout)
[WEBUI-LAT] leg=page-call   size=1024    side=page      n=20 min=14.7ms med=21.0ms max=23.9ms
[WEBUI-LAT] leg=page-call   size=65536   side=page      n=20 min=14.8ms med=17.5ms max=44.2ms
[WEBUI-LAT] leg=page-call   size=524288  side=page      n=20 min=33.6ms med=46.3ms max=91.0ms
[WEBUI-LAT] leg=page-call   size=4194304 side=page      n=20 min=219.3ms med=280.5ms max=365.6ms
[WEBUI-LAT] leg=page-ask    size=0       side=page      n=20 min=10.8ms med=14.5ms max=34.2ms
```

What the numbers settle:

- **The transport is ~12 ms round trip and flat to 512 KB.** `execjs-echo`
  medians are identical at 1 KB, 64 KB and 512 KB — fixed cost dominates;
  bytes only start to matter by 4 MB (~68 ms). The historical
  `618 ms at 1 KB / 701 ms at 3.8 MB` is **not reproduced** — nothing in any
  leg approaches it (worst 4 MB median anywhere: 280 ms). Whatever produced
  it — an earlier engine build, a loaded frame schedule, or measurement
  through a sleeping poll — it is not a property of the current bridge.
- **The polling-wait hypothesis above is answered: ~2 ms, not hundreds.**
  `fnc-call` minus `execjs-echo` at 1 KB = 13.7 − 11.7 ms. `webui_fnc_call`
  costs essentially the transport.
- **API.md's old `~15-21 ms` was real** — it matches `page-call` at 1 KB
  (median 21.0 ms). The two "contradictory" numbers were different legs, as
  §5 suspected; both docs now say which leg they mean.
- **`ask` is ~0.7× `call`** (14.5 vs 21.0 ms median), not the "roughly half"
  API.md used to claim. Right idea, wrong constant — corrected there.
- **`fnc-call` ≥ 64 KB does not fail for latency reasons at all.** The RPT
  shows the page's reply arriving as `["REPLY",21,true,"xxx…` — valid JSON
  **cut off mid-string**: the engine truncates the JSDialog message
  (page → SQF direction) at a cap somewhere between ~1 K chars (a ~1044-char
  reply passed 20/20) and 64 K (0/20). The reverse direction has no such
  limit — `execjs-echo` carried 4 MB in this same session, and `page-call`'s
  big rungs returned through ExecJS intact. **Design rule: big payloads flow
  SQF → page freely; page → SQF messages must stay under the cap or be
  chunked.** Exact cap: run `webui_fnc_msgCapProbe` (bisects both the
  SendAlert and SendConfirm carriers to the character):

<!-- RUN [] spawn webui_fnc_msgCapProbe AND PASTE THE [WEBUI-CAP] VERDICT ROWS HERE -->

What *was* verified by the original ladder and still stands: every rung from
1 KB to 3.8 MB **arrived intact in the SQF → page direction** — the probe
re-verifies this by failing a rung loudly rather than assuming it. Shipping an
asset from the server to a page at runtime therefore remains viable:
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

`webui_fnc_volumeSlave` reads `musicVolume` / `soundVolume` / `radioVolume` and
pushes them so the page can multiply its own gain by them, with distance riding
the same channel.

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
