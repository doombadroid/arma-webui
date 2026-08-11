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

## 5. ExecJS carries at least 3.8 MB

Every rung from 1,000 to 4,000,000 characters arrived intact, and cost barely
moved — 618 ms at 1 KB against 701 ms at 3.8 MB, nearly all of which is round
trip rather than payload. No ceiling was found.

So shipping an asset from the server to a page at runtime is viable: remoteExec
the bytes, push them in as a data URI, no client repack.

`Deflate` manages 329:1 and 381:1 on repetitive text, useful for the network leg
even though ExecJS plainly does not need it.

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
