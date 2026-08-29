# Pre-handoff test

Run this before giving the library to anyone. It takes about three minutes and
ends in one word.

The automated part is `webui_fnc_selfTest`. The manual part is four things a
script cannot check, listed at the bottom — do not skip them, because two of the
defects fixed on 2026-08-28 were invisible to everything except a human looking
at a screen.

---

## 1. Automated: one green/red verdict

Join, open the debug console (Esc → Debug Console), and run:

```sqf
[] spawn webui_fnc_selfTest;
```

It arms and waits up to 60 s. **Now open any web screen.** The test attaches to
that page, exercises the bridge, and prints a hint with a PASS/FAIL line per
check plus a verdict banner.

Run it a second time against a page that includes `prompt_overlay.hpp`, or the
prompt checks report SKIP rather than PASS — see the note under check 8.

### What each check means, and what a failure points at

| check | proves | if it fails |
|---|---|---|
| bridge is up | `webui_ready` was set | precondition 1 or 2 — whitelist, or `webui_fnc_init` never called |
| readiness did not fall to the 3s backstop | a real signal won | the boot delay is back; read the `[WEBUI]` lines in the RPT |
| readiness inside 1s | it was fast, not just eventual | see FINDINGS 10; healthy is 0.03–0.4 s |
| page → SQF call arrives | JSDialog handler + page can reach it | the page has no `A3API`, so it is not on a whitelisted path |
| SQF → page push lands | the queue drained into a document that really has the bridge | the page renders but the bridge is not in it |
| boot path is known | `WEBUI.bootPath` reported | webui.js is older than this test |
| serve callback survives an async fetcher | the closure fix holds | **regression** — `fn_serve`'s callback is reaching for locals again |
| prompt refuses re-entry while busy | one overlay, one prompt | **regression** — concurrent prompts can release each other |
| prompt generation not consumed by a refusal | stale presses cannot cross prompts | as above |
| exec queue is not backed up | nothing is flooding `webui_fnc_exec` | something pushes while the page is down — see the frozen-page case |

**Green means the automated surface is clean.** It does not mean the UI looks
right; nothing here renders anything.

### Things the verdict deliberately does not fail on

- **`clamped` frame delivery.** Reported in the hint, never counted as a
  failure. It means the game was not launched through Steam (FINDINGS 1), so
  pages sit at ~1 fps and every animation looks broken. That is a launch-path
  problem on that client, not a fault in the install — but if you are judging
  how anything *looks*, fix it first or you will chase ghosts.
- **`bootPath = sqf`.** Legal, and it works. It also means that page has no
  working self-boot stub, so it is on the slow, fragile path that depends on
  `loadFile` (FINDINGS 11). Fix it before handing over: INSTALL.md step 6.

---

## 2. Manual: four things no script can check

### a. The volume slider

`radioVolume` only moves when a person moves it, which is exactly how it went
unwatched for so long.

```sqf
[_ctrl] spawn webui_fnc_volumeSlave;
```

Open a page that plays audio. Move **only** the Radio slider. The page's gain
must follow. Then move Music and Effects and confirm those still work.

### b. The prompt overlay, on screen

The self-test covers the guard, not the look.

```sqf
[] spawn { private _c = uiNamespace getVariable ["WEBUI_ctrl", controlNull];
           diag_log str (["Rename", "current text", 24] call webui_fnc_prompt); };
```

Confirm: the box draws, the field takes focus, typing works, OK returns the
string, Cancel returns `nil`. Do this on a dialog that includes
`prompt_overlay.hpp` — a missing `colorBackgroundActive` on the button class
makes the engine drop the whole control class, so the overlay silently is not
there and `webui_fnc_prompt` just returns nil.

### c. Freeze and resume

```sqf
[_ctrl, false] call webui_fnc_freeze;   // last frame stays, browser stops
// wait a while, then:
[_ctrl, true]  call webui_fnc_freeze;   // reloads, fires PageLoaded again
```

The page must come back **with its data**, not blank and not stale. While it is
frozen nothing should be queueing — re-run the self-test's exec-queue check, or
just watch the RPT for `exec queue full, dropping`, which is the symptom of a
push loop that ignores a down bridge.

### d. A real screen, opened cold

Open the actual UI a player would use, from a fresh join. Everything above can
pass while a page is still wrong for its own reasons.

---

## 3. Read these before shipping the RPT to anyone

Two lines matter more than the rest:

```
[WEBUI] ready via '<signal>' <n>s after init
[WEBUI] inject: loadFile '<path>' (may abort here -- see FINDINGS 11)
```

The second has **no error line when it fails.** `loadFile` is refused in some
client contexts and aborts the calling thread uncatchably, so the signal is the
*absence* of the `inject: webui.js N bytes` line that should follow it. If you
see the first line and not the second, SQF's injector died and the page is
running on its own stub alone.

---

## 4. When the client is not yours

The whole reason the boot delay took so long to find is that it reproduced only
on someone else's server, on clients whose RPT nobody could read.

```sqf
[] spawn webui_fnc_bootProbe;      // arm, then open a page
```

Reports on screen via `hint`, needs nothing from the page, and works against
pages you cannot edit. A player screenshots it and sends it to you.
`webui_fnc_selfTest` reports the same way, so a third party can run the full
check themselves and send you one image.
