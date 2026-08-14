# arma-webui — video script

Working length ~9 min. Beats, not a teleprompter — the bracketed lines are what
to say, everything else is what to show.

---

## 0. COLD OPEN (0:00–0:25)

**Show:** the phone rolling open in game. Matrix rain behind the panels. Scroll a
list. Type into the message composer. Close on Esc, chassis winds shut.

> "That's Arma 3. That's not a mod, not an external overlay — that's a web page,
> running inside the game, talking to the mission."

Cut to black. Title.

---

## 1. WHY (0:25–1:40)

**Show:** `dialog/admin_menu.hpp` scrolling. Let it run — it's 936 lines.

> "If you've written Arma UI, you know the deal. Every dialog is a config class.
> Coordinates are a fraction of a screen with a safezone offset. There's no
> flexbox, no grid, no wrapping text. Want a rounded corner? That's a texture.
> Want an icon? That's a texture. Want a gradient? Texture."

**Show:** a folder of `.paa` files.

> "This mission has 111 of those dialog files."

**Show:** side-by-side — `deck_phone.hpp` (44 lines) next to the phone running.

> "This is the whole dialog for what you just saw. Forty-four lines. One control.
> Everything else is HTML."

---

## 2. WHAT IT IS (1:40–2:40)

> "Arma 3.20 added a browser control — type 106, `CT_WEBBROWSER`. It'll render a
> local page. On its own that gets you a picture: no way to get data in, no way
> to get a click back out.
>
> arma-webui is the part that makes it two-way. Fifteen SQF functions and one JS
> file — about 480 lines total — and then you write your UI in HTML and CSS like
> it's 2010 and you're happy about it."

**Show:** the four calls, on screen as text:

```js
WEBUI.on("money", v => render(v));       // game pushes → page
await WEBUI.call("buy", ["ammo", 3]);    // page asks → game answers
await WEBUI.ask("isCop");                // cheap synchronous-ish check
WEBUI.handle("alarm", fn);               // game calls into the page
```

> "Push, call, ask, handle. That's the whole surface."

---

## 3. THE DEMO (2:40–4:30)

**Show:** the phone, properly. Launcher → a list screen → the talent tree → the
market table → messages with real typing.

Talking points as you go:

- Every icon is inline SVG. **Zero** `.paa` files for this UI.
- One HTML file, ~2400 lines, covering seven screens.
- Real `<input>`. Search filters as you type.
- The row layout is flexbox. Try that in a `.hpp`.

> "And the data's real — that market table is reading the live price index off
> the server, the same numbers the dealers charge."

---

## 4. HOW THE BRIDGE ACTUALLY WORKS (4:30–6:00)

This is the bit the audience is here for. Keep it concrete.

**Game → page** is `ctrlWebBrowserAction ["ExecJS", ...]`. You're injecting a
JavaScript string. Serialise with `toJSON`, which arrives as a real JS object.

**Page → game** is the fun one:

> "There's no callback. What there *is* is a `JSDialog` event — the control fires
> it when the page calls `alert()`. So the page calls `alert()` with a JSON
> payload, SQF catches it, and answers by injecting JS back.
>
> You are tunnelling an RPC layer through `alert()`. It works, it's fast enough —
> about fifteen to twenty milliseconds round trip — and once it's wrapped you
> never think about it again."

**Show:** the round-trip in one diagram. Keep it 15 seconds, don't linger.

---

## 5. THE PART THAT COST ME A WEEK (6:00–7:40)

The honest section. This is what makes it worth watching.

**Two silent preconditions:**

> "The page has to be served from a path listed in `allowedHTMLLoadURIs` in
> description.ext. And you have to attach a `JSDialog` handler before the page
> loads. Miss either one and you get... a page. It renders perfectly. It just
> can't talk. No error, no warning, nothing in the RPT."

**The `JSDialog` return-value trap:**

> "Whatever your handler returns *is* the reply to the page. So if you `spawn` the
> work — which is the obvious thing to do — you return a script handle, and the
> page sits blocked inside `alert()` forever."

**The one that actually got me:**

**Show:** the fps counter, animation running at ~1 fps. Then the same thing at 60.

> "My animations ran at one frame per second. I blamed the control. I blamed
> Chromium background throttling. I wrote three different diagnostic harnesses.
>
> The frames are delivered *dirty-driven* — nothing changes, nothing is sent,
> which is correct and it's why a static screen is free. But mine wouldn't
> animate either.
>
> It was the launcher. I was starting the game from a shell script instead of
> through Steam. No Steam overlay, no `gameoverlayrenderer.so`, and the browser
> control just... doesn't get frames. Launch through Steam: one to twenty fps on
> a GIF, two to sixty on requestAnimationFrame. Same build, same page."

> "The owner told me it was probably my launch options. I filed that as noise for
> two days."

---

## 6. WHAT IT COSTS (7:40–8:20)

Be straight about it.

- Browser control on screen: measured **−1.1 fps**, A/B/A. Not free, not scary.
- A still page costs essentially nothing — it stops sending frames.
- A full-screen animation dirties everything every frame. That's the real bill.
- Mitigation: `animation-play-state: paused`. A paused animation is exactly as
  cheap as a static image, so the live wallpaper only runs on the home screen.

> "Which means you can have a live animated wallpaper *and* not pay for it while
> you're doing something else. You just have to say so."

---

## 7. SHOULD YOU USE IT (8:20–9:00)

> "If you're building anything list-heavy, table-heavy, or text-heavy — inventory,
> shops, admin panels, phones — yes. It's not close.
>
> If you need it to overlay the world, or you need it in the main menu, or you
> care about players on very old hardware, test first.
>
> It's MIT. It's not tied to my mission — the phone I showed you lives in a
> different repo and imports this as a folder."

**Show:** the repo, the README, the file list.

> "Link's below. The findings doc is the useful part — every wrong answer I had
> is in there next to the right one."

---

## B-ROLL SHOPPING LIST

- Phone roll-open and roll-shut (get a clean take of each)
- `admin_menu.hpp` scrolling fast — the 936-line wall
- `deck_phone.hpp` full-screen, all 44 lines at once
- Typing in the composer, close on the field
- Market table with the premium column moving
- fps counter: before/after the Steam launch fix
- Matrix rain running, then freezing as an app opens
- Repo file tree

## THINGS NOT TO CLAIM

- Don't say it replaces all Arma UI. It can't draw over the world usefully and
  native controls still layer on top of it.
- Don't quote a round-trip figure other than ~15–20 ms; that's what was measured.
- The −1.1 fps was one machine, one scene. Say so.
- Don't imply the Steam-launch behaviour is documented anywhere. It isn't. It's
  an observation from one setup and it may not generalise.
