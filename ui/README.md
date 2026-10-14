# The surface, and how it is drawn

`opx_infinity/ui` is ONE CEF page. Everything the player sees -- the HUD, the menu,
the inventory, the toasts, the name tags -- is a module inside it, and every module
is written in the same visual language.

This file is that language. The code is the authority: where a rule below and a style
block disagree, the style block is what ships and this file is out of date.

**The stack is one direction, and only one:**

```
design-system/        the shapes (every cut corner and every frame), then the OPX
                      vocabulary on them: tokens, presets, states, the plane
      ↓
modules/<name>/       what is true of THAT surface and of nothing else
```

---

## The look: red, outlined, tilted

Red by default, and **default is the operative word**: the accent is an operator
setting now. See [The theme](#the-theme). Everything below is written as though the
accent were red because on an unconfigured server it is, to the byte.

Pass 01 was cyan and yellow, filled, and built on shared Vue components. Pass 02 is
red, unfilled except for a dark ground under type, chamfered, and tilted on a
perspective. It was drawn against IDEDARY/Bevypunk and settled on the menu.

### The contract

1. **NOTHING IS FILLED** except the ground under type. State is a stroke going bright,
   never a block of colour.
2. **A CONTROL IS A CLOSED BOX** -- a thin frame with the top-right corner chamfered.
   The converse is load-bearing: **what is not a control does not get a frame.** A
   readout is a line of type; a separator is a 1px rule. A frame means "press this".
3. **`shapes.css` DRAWS EVERY SHAPE.** One attribute, and the state is one custom
   property. See [The shapes](#the-shapes).
4. **RED IS THE VOICE, SO RED CANNOT BE THE ALARM.** A red bar going redder inside a
   red frame says nothing. The escalation climbs in luminance and then leaves the hue:
   `--op-red-idle` → `--op-red` → `--op-red-hi` → `--op-alarm`, which is **white-hot**.
5. **THE TILT COMES FROM THE ANCHOR.** Left-anchored is `+7deg` about the left edge,
   right-anchored `-7deg` about the right, centred is **none** -- rotating a centred
   plane about its middle is paper on a spindle, not a surface receding. A name tag is
   pinned to a body in the world and takes no tilt at all: the world supplies one.
6. **ONE INK SHADOW PER SURFACE**, declared on the root and inherited. An override
   replaces the whole list, so a block wanting a bloom restates both passes plus it.
7. **NO SECOND HUE.** There is no second accent, no green, no yellow. Each would have
   solved some problem in one line, and each puts a second saturated hue on an unfilled
   red surface over live gameplay. The **alarm** is the single sanctioned exception, and
   only because its whole job is to be unlike the voice: an operator may set it outright
   (`ALARM` in `config/theme.lua`) where the derived white-hot rung would read as one
   more shade of their own accent.
8. **TECHNICAL FILLER IS CONTENT.** A mono micro-label is part of the look and must
   state something the surface knows -- a row index, a toast's kind. Never invented
   chrome text.
9. **THE INTERLACE GOES ON WHAT IS ENCLOSED.** A surface with no frame does not take
   it: a striped rectangle with nothing around it *is* the floating rectangle the
   interlace exists to prevent.

---

## The shapes

Every chamfer in the runtime is drawn by the first block of `design-system/shapes.css`.
It speaks augmented-ui's vocabulary -- the attribute, `--aug-tr`, `--aug-bl`,
`--aug-border-all`, `--aug-border-bg` -- but the library itself is gone (#112): the
templates only ever used three of its tokens, and its 130 kB core evaluated a polygon
of some forty `calc()` points on every augmented element at every style recalc. The
hand-written block is the same polygons for those three tokens, pixel for pixel, and
the build refuses any other token (`guardAugmented` in `vite.config.ts`).

| Token | What it draws |
|---|---|
| `tr-clip` | the top-right corner cut at 45deg, `--aug-tr` deep (15px if nothing sets it) |
| `bl-clip` | the same at the bottom-left, `--aug-bl` |
| `border` | the border layer on `::after`: a ring `--aug-border-all` wide, painted with `--aug-border-bg` |

An element says what it is with a preset class and asks for the border layer:

```html
<div class="row op-frame" data-augmented-ui="tr-clip border">
```

```css
.op-frame { --aug-tr: var(--op-cut-sm); background: var(--op-plate); }
.op-frame.is-on { --aug-border-bg: var(--op-red); --aug-border-all: 2px; }
```

| Preset | What it is | Cut |
|---|---|---|
| `.op-frame` | a control: closed box, chamfered top-right | `--op-cut-sm` |
| `.op-bay` | an enclosure holding a list or a grid, two opposite corners | `--op-cut-lg` |
| `.op-cap` | a keycap -- a mark, so **no ground** | `--op-cut-sm` |

States are `.is-on`, `.is-off`, `.is-alarm` and `:hover`, and each is one
`--aug-border-bg`. `.op-arete` lights the leading edge; `.is-end` mirrors it for a
right-anchored surface. `.op-lift` is the bloom.

### What must be known before touching this

- **Declare the cut on the element itself.** `tr-clip` sets `--aug-tr: 15px` on the
  element it is written on, so an ancestor's `--aug-tr` never reaches it: carry a
  preset class or declare the cut in the element's own rule. (`HudVitals` sets the
  cut on the gauge row, and its track is drawn at the 15px default -- which is what
  the owner signed off on, so it stays until someone decides otherwise.)
- **One border width.** `--aug-border-all` is the only width there is; the library's
  per-side `--aug-border-top` and friends were never used and are not implemented.
- **A clip shears an outset `box-shadow`.** The element is clipped, so a bloom
  is `.op-lift` (a `drop-shadow`, which follows the cut) or it is nothing. Several
  files carried a written defence of `box-shadow` that was true only while they were
  unclipped; the defence went with the sprite.
- **A filter costs a backing store.** Never on anything whose value changes every
  frame. The HUD repaints at 30Hz and carries exactly one, on the rx counter, which
  appears when somebody talks rather than on a clock.
- **`::before` is yours, `::after` is not.** The border layer is `::after`. Asking for
  `border` without `inlay` leaves `::before` free, which is what `.op-interlace` uses.
- **Augment containers, not cells.** A 40-slot grid is one bay and forty cells; the
  cells are augmented only because each needs the cut and the ground, and they ask for
  the border layer alone so it is one pseudo-element each rather than two.

---

## The theme

The accent is the server's, not this repo's. `config/theme.lua` on the server holds one
hex and five knobs; `modules/theme` validates them, derives the rest and sends the
result to the page; `design-system/theme.ts` writes it onto `:root` as custom
properties. Nothing is rebuilt -- the tokens were already the one place a value is
decided, so overriding them is the whole mechanism.

**An unconfigured server overrides nothing.** A knob the operator did not set produces no
key on the wire, the page writes no property, and `tokens.css` stands. That is why
there are no defaults on the Lua side or in `theme.ts`: the stylesheet is the default.

**What this changed in here.** Every themeable colour is now a channel triple plus a
composition of it -- `--op-red-rgb` and `--op-red: rgb(var(--op-red-rgb))` -- because
nine surfaces wanted one of the reds at an alpha of their own and each had copied the
channels out as a literal. Those copies are gone; a surface that wants the idle red at
0.22 writes `rgba(var(--op-red-idle-rgb), 0.22)`. The plate alphas are tokens for the
same reason, and the interlace is a colour token (`--op-interlace`) rather than an rgba
written into three separate gradients.

**The rules that follow from it:**

- **Never write an accent channel as a literal.** `rgba(232, 67, 79, 0.7)` does not
  follow a theme and nothing warns you; `rgba(var(--op-red-idle-rgb), 0.7)` does.
- **Never write a cut or a tilt as a literal** for the same reason. `--aug-tr: 6px` was
  the one cell in the runtime that did, and it stopped scaling with everything else.
- **The wire carries numbers, never CSS.** A colour is three integers; `theme.ts` is the
  only thing that produces `rgb()`, `px` or `deg`. Adding a themeable value means an
  entry in `KNOBS` and a bound in `palette.lua`, and the entry is the allowlist.
- **What is not themed:** border weights (thirty-nine component-local declarations at six
  values, with no token behind them), type scale (fixed pixel layouts are configured
  elsewhere), and the neutral ramp, which is neutral on purpose.

### The join screen is outside all of this

`web/loading.html` is the server's declared load screen. It runs **before the bundle
exists**, so `theme.ts` is not loaded and no custom property ever reaches it — an
operator who changes `ACCENT` recolours everything except this page.

It is therefore the one file allowed to declare tokens of its own: a hand copy in
`:root`, labelled as a copy, listing only what the page uses. Its copy of augmented-ui is
inlined into it for the same reason, and because the client has no guaranteed internet.

Two consequences worth knowing before you touch it. **A change to `tokens.css` does not
reach it** — mirror it by hand or the two drift. And `ui/public/` is a Vite public
directory, so **`npm run build` copies `ui/public/loading.html` over `web/loading.html`**:
edit the one under `ui/public/`, and expect the built copy to follow.

### The ripperdoc screen is the base game's, not ours

`modules/ripperdoc/Ripperdoc.vue` is the second exception, and it is one on purpose:
the players asked for the clinic to be the base game's own 2.0 ripperdoc screen, so
it follows the game's widget (`base\gameplay\gui\fullscreen\ripperdoc\ripperdoc.inkwidget`,
2.31) instead of the contract above. Its header comment says where each part comes
from; in short:

- **Layout** in the widget's own 3840x2160 units (`--u`, one unit per 4K pixel,
  scaled by the screen's height): the body in the middle, the ten systems at the
  widget's anchors, the capacity and armor meters left and right, a system opened as
  the widget's inventory tab, the item tooltip docked beside it, the purchase popup.
- **Shapes** are the game's own atlas parts, not augmented-ui: white, sliced where
  the atlas slices them, and tinted with `-webkit-mask-box-image`. They are cut by
  `tools/ripperdoc-art.py` into `modules/ripperdoc/art/` and inlined by the build;
  the paperdoll bodies go to `public/images/ripperdoc/`.
- **Colour** is the game's, read from its inkstyles (`MainColors.*`, `Rarity.*`),
  declared once as `--rd-*` on the component's root. The operator's theme does not
  recolour this screen, and a green, a yellow and the five tier colours appear on it,
  because they appear on the game's.
- **Type** is the game's face, Rajdhani, at the widget's sizes; `design-system/fonts.css`
  carries its Medium weight for this screen.

What still holds here is everything that is not the look: the page decides nothing,
every press is an intent, every list is bounded and coerced, and every file it ships
keeps inside the path budget.

---

## The one sprite left

`InventorySlot.vue` keeps a single SVG data URI, for the **drag** state: four corner
brackets and no edges. That is a *shape class* change, not a colour change, and
the border layer is a continuous ring around the clip path. The cell's
augmentation is therefore bound rather than static --
`:data-augmented-ui="dragging ? undefined : 'tr-clip border'"` -- so the dragged cell
is unclipped and its sprite paints the brackets whole.

Forty other sprites are gone. They were inline 9-slice SVGs, one per state per
surface, each a copy of the same chamfer path with one number changed, plus a black
under-stroke baked in because a `border-image` cannot take a shadow.

---

## Layout

| File | What it decides |
|---|---|
| `design-system/tokens.css` | every value: the red ladder, the grounds, the neutral ramp, type, space, shape, motion |
| `design-system/theme.ts` | the operator's overrides, written onto `:root` at runtime |
| `design-system/shapes.css` | the three presets, the states, `.op-arete`, `.op-lift` |
| `design-system/surface.css` | the plane and tilt, the ink, the interlace, four type roles, the entrance |
| `design-system/fonts.css` | the three faces, inlined by the build |
| `boot/` | the one `createApp`, the two layers, the module registry |
| `bridge/` | the channel, rpc, focus and diagnostics -- no module talks to CEF directly |
| `modules/<name>/` | one surface each |

**`overlay` vs `modal`** is declared per module in `boot/registry.ts` and decides
style as much as behaviour. An overlay surface is never focused, takes no pointer, and
has no backing of any kind; a modal surface takes focus and the cursor while open.
Two more layers stack above them, neither taking a pointer: `notice` (the toasts, so a
refusal is never dimmed under the scrim of the view that caused it) and `cover` (the
loading cover, over everything).

---

## There is no shared row component, and that is deliberate

A menu row, a target row, an inventory cell and a panel row look alike and behave
nothing alike. One shared row is what coupled five surfaces together in pass 01 --
changing it changed every surface at once, which is why each of them ended up with a
local copy anyway. What is shared is the *vocabulary*, not the markup: a surface draws
its own row out of `.op-frame`, the states and the type roles, and adds the twenty
lines that are true of that row alone.

Wrap something in a component when it carries real behaviour, not to avoid repeating a
class list.
