<script setup lang="ts">
import { computed, onUnmounted, ref } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus, focusOwner } from '@/bridge/focus'
import { num, text, records, own } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { GLYPHS } from '@/modules/target/glyphs'

/**
 * THE MENU -- port of `opx77_menu/web/{index.html,menu.css,menu.js}`.
 *
 * The strip is a RENDERER and nothing else, exactly as the original was: Lua owns the
 * navigation stack, the cursor and the window of rows, and `opx:menu:frame` is the
 * window it decided to draw. Nothing here moves a cursor, flips a checkbox or resolves
 * a submenu -- see `opx77_menu/docs/ARCHITECTURE.md`, "Navigation", where every one of
 * those lives in `client/model.lua`.
 *
 * ONE THING MOVED, and it had to. The original page was created on the `hud` layer
 * precisely so it could never be focused, and Lua read the six keys itself through
 * `Open77.input.isDown` with its own 260ms/55ms repeat machine. This surface DOES take
 * focus, so the keystrokes now land here first -- which makes the page the only thing
 * that can see them. It forwards each one as an intent (`opx:menu:key`) and waits to be
 * told what it meant, which is the same division of labour by a different route. The
 * repeat machine is gone with it: the browser's own key repeat is the same edge
 * detector, and `event.repeat` rides along so Lua can still tell a press from a hold.
 *
 * ── THE REFERENCE SURFACE ───────────────────────────────────────────────────
 *
 * This file settled the look, so it is the one the rest of the runtime copies. It
 * carried a local frame, a local row, a local red ladder, a local ink shadow and a
 * local interlace while that was being settled; all five are in `design-system/` now
 * and this file keeps only what is true of a MENU.
 *
 * IT IS DRAWN BY AUGMENTED-UI, and the three reasons this file used to give for not
 * using it were checked against `node_modules/augmented-ui/augmented-ui.css` and two
 * of them were wrong:
 *
 *   1. "`--aug-border-bg` is one colour on four sides." It is assigned to
 *      `background`, so it takes a gradient, and the per-side WIDTHS are separate
 *      properties. The lit leading arete is `.op-arete`, a gradient across the
 *      border layer.
 *   2. "It spends both pseudo-elements." Only with both layers on. `::after` is the
 *      border and `::before` is the inlay, each `content: none` while its layer is
 *      off -- so asking for `border` alone leaves `::before` free, which is what
 *      `.op-interlace` uses here.
 *   3. "A clip shears an outset shadow." TRUE, and it is the one thing that changed:
 *      the chosen row's bloom is `.op-lift`, a `drop-shadow` that follows the cut.
 *
 * Nothing about the protocol changed. Same channels, same handle guard, same keys,
 * same `choose` intent. The player sees the same surface; it is drawn with four
 * fewer sprites and no local copy of anything.
 */

/** Lua's handle, echoed back untouched. Never coerced -- an integer must stay one. */
type Handle = string | number

interface Slot {
  /** The row's ABSOLUTE index in the level, which is also the v-for key. */
  index: number
  /** The row's place in the OPEN stagger, and 0 on every frame after it: the walk
      down the column belongs to the menu arriving. A row that scrolled into the
      window one keypress later would otherwise sit invisible through a delay
      measured for nine rows before it faded in. */
  stagger: number
  label: string
  /** A glyph name from the closed set Lua validates against, or '' for none. */
  icon: string
  value: string
  /** `>` descends, `<>` means LEFT and RIGHT change the value beside it. */
  mark: string
  rule: boolean
  /** A separator with no caption: pure space, per menu.css `.rule.blank`. */
  blank: boolean
  off: boolean
  on: boolean
  /** `undefined` means no checkbox at all, not an unchecked one. */
  checked: boolean | undefined
}

/** The six keys of `opx77_menu/client/input.lua`, as the browser names them. */
const KEYS: Record<string, string> = {
  ArrowUp: 'up',
  ArrowDown: 'down',
  ArrowLeft: 'left',
  ArrowRight: 'right',
  Enter: 'enter',
  Backspace: 'back'
}

const ANCHORS: Record<string, string> = {
  'top-left': 'anchor-top-left',
  'top-right': 'anchor-top-right',
  'left': 'anchor-left',
  'right': 'anchor-right',
  // THE PANEL, for a menu whose owner asked for one: centred, and centred is the
  // ONLY anchor a menu may take per open -- see `readConfig`. A menu down an edge
  // is a strip; a menu in the middle of the screen is a panel, and a caller that
  // wants the second says so here.
  'center': 'anchor-center'
}

/** How long a closed menu keeps its rows on screen: past the strip's 90ms fade, with
    room to spare, so the rows leave once nothing can see them go. */
const WIPE_MS = 240

/** Bumped on every open and folded into the row keys, so a menu opened while the last
    one's rows are still fading out gets new elements and its own entrance, instead of
    inheriting the old rows' elements because their indices match. */
const generation = ref(0)

const handle = ref<Handle | null>(null)
const open = ref(false)
const hint = ref('')
const slots = ref<Slot[]>([])
const first = ref(1)
const total = ref(0)
const anchor = ref('anchor-top-left')
const focusMode = ref('full')
const closable = ref(true)
const width = ref(340)
const maxHeight = ref(56)
/** A HEIGHT IN PIXELS, or 0 for none -- which is every menu but a panel. A strip's
    height is its rows; a caller that asked for a panel named a height as well, because
    a four-row level at a reading width would otherwise draw a bar rather than the
    square it asked for. Read and CLEARED on every open: the key is absent when the
    caller named none, and a panel's height must not survive into the next menu. */
const height = ref(0)

/** Right-anchored strips read the leading edge as the right edge, per menu.css. The
    curve follows it: a strip on the right recedes the other way. */
const railEnd = computed(() => anchor.value.endsWith('right'))

/* NEITHER THE RAIL NOR THE COUNTER SURVIVES. menu.css drew a track and a thumb at the
   window's proportions; pass 02 replaced it with a `03-09/24` readout in the header;
   the header is gone now and the readout with it. `first` and `total` are still read
   off every frame because Lua sends them and they cost nothing to hold -- but the strip
   says where the window sits by what it is showing, and nothing else. */

/** The paths of one glyph, empty for a row that carries none and for a name this page
    does not know. The set is CLOSED and Lua refuses an item naming anything outside it,
    so an empty answer here means a row with no icon, never a silent typo.

    Imported from the target module rather than re-declared: it is one closed set shared
    by two surfaces. It belongs in `design/` and moves there when this pass is promoted. */
function paths(name: string): string[] {
  return (name && own(GLYPHS, name)) || []
}

const stripStyle = computed(() => {
  const box = `width: ${width.value}px; max-height: ${maxHeight.value}vh`
  // `max-height` still wins over this, so a window too short for the panel clips it
  // rather than drawing off the screen -- the guard stays the guard.
  return height.value > 0 ? `${box}; height: ${height.value}px` : box
})

/** Which edge the plane is hinged on. The tilt's sign, its origin and the
    chosen row's step all derive from it, in `design-system/surface.css`.

    A CENTRED MENU TAKES NEITHER, and that is the design system's own rule for a
    centred surface: rotating about the middle sends half the panel toward the
    player and half away, which is paper on a spindle rather than a surface
    receding. `.op-plane` is still on the strip, so the perspective and the
    containment stay; only the hinge goes. */
const plane = computed(() =>
  anchor.value === 'anchor-center' ? '' : railEnd.value ? 'op-anchor-right' : 'op-anchor-left'
)

function isHandle(value: unknown): value is Handle {
  return typeof value === 'string' || typeof value === 'number'
}

/** A payload for a handle that is not the open one is DROPPED, never applied. */
function mine(payload: Payload): boolean {
  return handle.value !== null && payload.handle === handle.value
}

function readConfig(payload: Payload): void {
  anchor.value = own(ANCHORS, text(payload.anchor)) ?? ANCHORS['top-left']
  const wide = num(payload.width)
  if (wide > 0) width.value = Math.round(wide)
  const tall = num(payload.maxHeight)
  if (tall > 0) maxHeight.value = Math.round(tall)
  // Reset rather than keep: an absent key means the caller named no height, and the
  // panel before this one must not decide this one's shape.
  const box = num(payload.height)
  height.value = box > 0 ? Math.round(box) : 0
}

function readFrame(payload: Payload, stagger = false): void {
  hint.value = text(payload.hint)
  first.value = Math.max(1, num(payload.first, 1))
  total.value = num(payload.total)

  const rows = records(payload.rows)
  slots.value = rows.map((row, at) => {
    const rule = row.rule === true
    const label = text(row.label)
    return {
      index: first.value + at,
      stagger: stagger ? at : 0,
      label,
      icon: rule ? '' : text(row.icon),
      value: rule ? '' : text(row.value),
      mark: row.arrow === true ? '>' : row.spin === true ? '‹›' : '',
      rule,
      blank: rule && label === '',
      off: row.off === true,
      on: row.on === true,
      checked: row.check === true && !rule ? row.ticked === true : undefined
    }
  })
}

/** Blanked on hide, not on the next open, so nothing of this menu is left behind for
    the next one. Straight from menu.js `hide()` -- with one change: the rows go when the
    fade has FINISHED. They went in the same tick as `open`, so for the whole fade the
    player watched an empty bay collapse to a sliver and then disappear. A frame arriving
    during the fade cannot redraw them: `mine()` drops it, the handle is already gone. */
let wipe: ReturnType<typeof setTimeout> | undefined

function cancelWipe(): void {
  if (wipe !== undefined) clearTimeout(wipe)
  wipe = undefined
}

function blank(): void {
  open.value = false
  cancelWipe()
  wipe = setTimeout(() => {
    wipe = undefined
    if (open.value) return
    slots.value = []
    hint.value = ''
    total.value = 0
  }, WIPE_MS)
}

/* Focus is held for exactly as long as a menu is open, and released by whatever ends it
   -- Lua's close, or this module being unmounted by ModuleHost after a throw. A module
   that died holding focus is a player who cannot move. */
let release: (() => void) | undefined

function keyDown(event: KeyboardEvent): void {
  // Escape belongs to bridge/focus.ts, which handles it in the capture phase and calls
  // `onEscape` below. Reading it here as well would send the intent twice.
  if (event.key === 'Escape') return
  // Only while the menu is the TOP of the focus stack. The listener lives on `window`
  // for as long as a full menu is open, and a panel, confirm or form opened over it
  // had its Backspace, Enter and arrows swallowed here -- and sent to the hidden menu
  // as `opx:menu:key`, so the menu moved behind the surface being typed into.
  if (focusOwner() !== 'menu') return
  const key = KEYS[event.key]
  if (key === undefined) return
  event.preventDefault()
  emit('opx:menu:key', { handle: handle.value, key, repeat: event.repeat === true })
}

function listen(on: boolean): void {
  if (on) window.addEventListener('keydown', keyDown)
  else window.removeEventListener('keydown', keyDown)
}

useBridge('opx:menu:open', (payload: Payload) => {
  guard('menu:open', () => {
    if (!isHandle(payload.handle)) return
    // A second open replaces the first rather than stacking: the resource allows one
    // menu at a time and the previous handle is dead the moment this one arrives.
    release?.()
    release = undefined
    listen(false)
    cancelWipe()
    generation.value += 1
    handle.value = payload.handle
    readConfig(payload)
    readFrame(payload, true)
    open.value = true

    // HOW THIS MENU TAKES INPUT. `full` is what every menu did before the option
    // existed, and taking the keyboard is taking the movement keys -- so a menu meant
    // to sit open while the player walks asks for `cursor` and is navigated by
    // pointing at rows. The keydown listener is only worth installing when the
    // keystrokes can actually reach this page.
    focusMode.value = text(payload.focus, 'full')
    closable.value = payload.closable !== false
    listen(focusMode.value === 'full')

    if (focusMode.value !== 'none') {
      release = acquireFocus({
        id: 'menu',
        // An INTENT. The page does not close itself: Lua owns the close reason
        // (`pause`, `back`, `item`, ...) and answers with `opx:menu:close`. A menu
        // its owner declared unclosable gets a handler that does NOTHING -- never an
        // absent one: bridge/focus.ts treats a missing `onEscape` as "Escape releases",
        // which announced an empty stack and handed the player's movement back while
        // the unclosable menu stayed drawn.
        onEscape: closable.value
          ? () => emit('opx:menu:dismiss', { handle: handle.value })
          : () => {}
      })
    }
  }, undefined)
})

useBridge('opx:menu:frame', (payload: Payload) => {
  guard('menu:frame', () => {
    if (!mine(payload)) return
    readFrame(payload)
  }, undefined)
})

useBridge('opx:menu:close', (payload: Payload) => {
  guard('menu:close', () => {
    // A close with no handle closes whatever is open; one naming a dead handle is a
    // late message about a menu that has already gone and is dropped.
    if (payload.handle !== undefined && !mine(payload)) return
    handle.value = null
    blank()
    listen(false)
    release?.()
    release = undefined
  }, undefined)
})

onUnmounted(() => {
  cancelWipe()
  listen(false)
  release?.()
})

/** The cursor, pointed at. Lua re-resolves the index and decides what landing there
    means -- this says where the player pointed, never what happened. */
function choose(row: Slot): void {
  if (row.rule || row.off) return
  emit('opx:menu:choose', { handle: handle.value, index: row.index })
}
</script>

<template>
  <div class="strip op-plane op-ink" :class="[anchor, plane, { open, end: railEnd }]" :style="stripStyle">
    <div class="bay op-bay op-arete" :class="{ 'is-end': railEnd }" data-augmented-ui="tr-clip bl-clip border">
      <!-- NO HEADER. The reference has none: its main menu is a bare column of
           framed rows under a logo, and its character panel is a bare column of
           framed rows under nothing at all. The title and the breadcrumb Lua
           sends still arrive and are simply not drawn -- so a nested screen no
           longer says where it is, which is the cost of this and is deliberate. -->
      <div class="bay-inner op-interlace">
        <ul class="list">
          <!-- A KEYED v-for, where the original reused a fixed window of <li> slots.
               Its reason -- "a fresh element has no previous computed style, so menu.css
               could not transition it" -- is satisfied better here: the key is the row's
               ABSOLUTE index, so a row that stays in the window across a frame keeps its
               element even when the window scrolls under it, and the fill and tick
               transitions run. The original's slot reuse kept element 3 alive while the
               row standing in it changed, which transitioned the wrong thing. -->
          <li
            v-for="row in slots"
            :key="`${generation}:${row.index}`"
            class="slot op-enter"
            :class="{ gap: row.blank }"
            :style="`--op-slot: ${row.stagger}`"
          >
            <!-- A separator with no caption draws nothing at all: the <li> is the space. -->
            <div v-if="row.rule && !row.blank" class="sep op-eyebrow">{{ row.label }}</div>

            <div
              v-else-if="!row.blank"
              class="row op-frame"
              :class="{ on: row.on && !row.off, 'is-on': row.on && !row.off, 'op-lift': row.on && !row.off, 'is-off': row.off }"
              role="button"
              :aria-disabled="row.off"
              @click="choose(row)"
            >
              <!-- A GLYPH WHERE THE ORDINAL WAS. `01 02 03` told the player which row
                   they were on, which the cursor already says louder; an icon says what
                   the row IS, which nothing else on the strip does. The column is held
                   open whether or not this row carries one, so a menu that ices half its
                   rows still has its labels on one x. -->
              <span class="glyph" aria-hidden="true">
                <svg v-if="paths(row.icon).length" viewBox="0 0 24 24">
                  <path v-for="(d, at) in paths(row.icon)" :key="at" :d="d" />
                </svg>
              </span>
              <span class="label op-label op-truncate">{{ row.label }}</span>
              <span v-if="row.value" class="value op-value op-truncate">{{ row.value }}</span>
              <span
                v-if="row.checked !== undefined"
                class="check"
                :class="{ ticked: row.checked }"
                role="checkbox"
                :aria-checked="row.checked"
              >
                <!-- The tick draws in after the fill lands and wipes instantly: a
                     stroke-dashoffset transition with a delay, straight out of menu.css. -->
                <svg viewBox="0 0 13 13" aria-hidden="true"><path d="M2.6 6.8 5 9.2 10 3.6" /></svg>
              </span>
              <span v-if="row.mark" class="mark">{{ row.mark }}</span>
            </div>
          </li>
        </ul>

        <!-- NO STATUS LINE. It was a second, weaker notification channel: a
             confirmation written into a footer only a player already looking at
             the menu could see, expiring on a timer nobody was watching. Lua
             reroutes `SetStatus` to a toast now, so the same line still reaches
             the player -- somewhere they are actually looking. The hint stays:
             it describes the row under the cursor and belongs to the strip. -->
        <div v-if="hint" class="foot">
          <p v-if="hint" class="hint op-copy">{{ hint }}</p>
        </div>
      </div>
    </div>
  </div>
</template>
<style scoped>
/* =============================================================================
   THE MENU -- the reference surface, on the design system.

   This file settled the look, so it is the file the rest of the runtime copies.
   What it carried until now, and no longer does: four inline SVG frame sprites,
   its own copy of the red ladder, its own ink shadow, its own interlace
   gradient, its own perspective and tilt maths, its own stutter keyframes. All
   six were duplicated verbatim across ten other surfaces. They live in
   `design-system/` now and this file says only what is true of a MENU.

   THE LOOK IS UNCHANGED, deliberately and checkably: same three reds, same
   20px bay cut and 6px row cut, same 7deg tilt hinged on the anchored edge,
   same interlace, same stutter, same `--pop` step out of the column for the
   chosen row.

   WHAT THE SHAPES COST NOW. A row is `data-augmented-ui="tr-clip border"`: one
   attribute, and its state is `--aug-border-bg` plus `color`. Before, a row
   held a `border-image-source` pointing at one of four data URIs, each a copy
   of the same path, and `border-image-width: 8px` against a `border-width: 1px`
   so the corner tile would not shrink. The geometry is CSS now, so the cut size
   is a token rather than a redrawn sprite.

   THE ONE THING THAT HAD TO CHANGE. augmented-ui clips the element, and a clip
   shears an outset `box-shadow` along the diagonal -- so the chosen row's bloom
   is `.op-lift`, a `drop-shadow` that follows the cut. A filter is allowed here
   and forbidden on the HUD for the reason `shapes.css` gives: a menu repaints
   when a key is pressed, the vitals stream repaints thirty times a second.
   ========================================================================== */

/* =============================================================================
   THE STRIP -- the positioned wrapper, so it carries the perspective and the
   containment. `.op-plane` owns both; the anchor classes below only say which
   edge this strip is hinged on.
   ========================================================================== */
.strip {
  position: absolute;
  display: flex;
  max-width: calc(100vw - var(--op-inset-x) * 2 + var(--op-bleed) * 2);
  opacity: 0;
  pointer-events: none;
  transition: opacity var(--op-dur-fast) linear;
}

.strip.open {
  opacity: 1;
  pointer-events: auto;
}

/* EVERY OFFSET PAYS THE BLEED BACK. `.op-plane` pads by `--op-bleed` so that a
   bloom has room inside the paint containment, and padding moves the strip; the
   anchors subtract exactly what it added, so the bay lands where `--op-inset-*`
   says and the 10px of room is invisible. */
.anchor-top-left,
.anchor-left {
  left: calc(var(--op-inset-x) - var(--op-bleed));
}

.anchor-top-right,
.anchor-right {
  right: calc(var(--op-inset-x) - var(--op-bleed));
}

.anchor-top-left,
.anchor-top-right {
  top: calc(var(--op-inset-y) - var(--op-bleed));
}

/* The mid band: below the minimap and above the control hints. */
.anchor-left,
.anchor-right {
  top: calc(33vh - var(--op-bleed));
}

/* THE CENTRED MENU -- the panel a caller asked for, rather than a strip down an
   edge. Nothing to pay back here: the bleed is symmetric padding, so it cancels
   against itself and the bay lands dead centre. The tilt is absent on purpose,
   per `design-system/surface.css`, and the hinge vars are set to what the two
   plane classes would have set so a centred menu steps its chosen row exactly
   like an anchored one. */
.anchor-center {
  left: 50%;
  top: 50%;
  transform: translate(-50%, -50%);
  --op-pop: 10px;
  --op-origin: center center;
}

/* =============================================================================
   THE BAY -- the enclosure. Two opposite corners cut, which reads as a plate
   slid into place; `.op-bay` says that and `.op-arete` lights the leading run.
   ========================================================================== */
.bay {
  position: relative;
  flex: 1;
  min-width: 0;
  /* A COLUMN SO A FIXED HEIGHT FALLS THROUGH. When the caller named a height the strip
     is taller than its rows, and without this the bay would keep its content height
     and leave the panel's bottom empty instead of holding the hint down on it. */
  display: flex;
  flex-direction: column;
  /* THE DIAL, AND IT STAYS AT 0. The ground belongs on the ROWS, not on the
     bay: a bay is mostly the space BETWEEN rows, so a plate here fills what
     carries nothing and turns the strip into a window. One number to turn if a
     bay ever has to be closed over a plaza, on the same rgb as `--op-plate` so
     turning it up lands on the ground the rows already sit on. */
  background: rgba(var(--op-plate-rgb), var(--op-menu-veil, 0));
}

.bay-inner {
  position: relative;
  z-index: 1;
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
  /* In a bay taller than its rows, the LIST takes the room and the hint keeps its
     own at the foot, which is where a panel's last line belongs. */
  max-height: inherit;
}

/* =============================================================================
   THE LIST -- it never scrolls: Lua sends the window it wants drawn.
   ========================================================================== */
.list {
  position: relative;
  display: flex;
  flex-direction: column;
  /* The free room of a bay taller than its rows, so the foot is pinned to the panel's
     bottom rather than floating under the last row. The rows keep their own height at
     the top either way: this is what grows, not they. */
  flex: 1;
  gap: var(--op-space-1);
  margin: 0;
  /* The trailing padding is the chosen row's runway: it leaves the column by
     `--op-pop` and the perspective scales it slightly wider on the way out, and
     both have to land inside the bay, which clips. */
  padding: var(--op-space-3) var(--op-space-4) var(--op-space-3)
    calc(var(--op-space-3) + var(--op-rule));
  list-style: none;
  min-height: 0;
}

/* THE ENTRANCE IS ON THE SLOT, NOT ON THE ROW, and that is the whole of why this
   strip felt slow to move through. A row's classes change on every keypress --
   `.on` arrives on one and leaves another -- and an `animation-name` that differs
   between those two states is CANCELLED AND RESTARTED by the change, so both
   rows replayed the 190ms stutter from behind a delay of up to 264ms and were
   invisible for the whole wait. The <li> is what the keyed v-for creates, its
   classes say nothing about the cursor, and its transform composes with the
   chosen row's step out of the column -- so the open still lands that row
   popped, and moving the cursor replays nothing. */
.slot {
  display: flex;
  min-width: 0;
}

/* A separator with no caption is pure space: the gap, doubled. */
.slot.gap {
  height: var(--op-space-1);
}

/* =============================================================================
   A ROW -- a closed frame with a chamfered top-right corner, and text. The
   frame, the ground and all four states come from `.op-frame`; what is here is
   what a menu row is shaped like.
   ========================================================================== */
.row {
  position: relative;
  flex: 1;
  display: flex;
  align-items: center;
  gap: var(--op-space-3);
  min-width: 0;
  padding: var(--op-space-2) var(--op-space-3) calc(var(--op-space-2) + 1px);
  white-space: nowrap;
  cursor: pointer;
  /* The step out of the column is the ONLY thing that moves when the cursor
     does, so it is the cursor's travel rather than an entrance and is timed
     like one: long enough to read as a step, short enough that a held arrow key
     never queues. */
  transition:
    color var(--op-dur-fast) linear,
    transform 80ms var(--op-ease);
}

/* The column is held open by the span whether or not a glyph is inside it, so a
   menu that ices half its rows still has every label on one x. */
.glyph {
  flex: none;
  display: block;
  width: 16px;
  height: 16px;
}

.glyph svg {
  display: block;
  width: 100%;
  height: 100%;
  fill: none;
  /* The stroke follows the row colour, so the whole icon restates on hover and
     on the chosen row without a second declaration anywhere. */
  stroke: currentcolor;
  stroke-width: 1.9;
  stroke-linecap: round;
  stroke-linejoin: round;
}

/* Both take `.op-truncate` in the template: one line, cut with an ellipsis, per
   `design-system/surface.css`. This file says only where they sit. */
.label {
  flex: 0 1 auto;
}

.value {
  flex: none;
  margin-left: auto;
  max-width: 45%;
  opacity: 0.88;
}

/* The affordance column, always last so every mark lands at the same x. */
.mark {
  flex: none;
  font: 700 var(--op-fs-meta) / 1 var(--op-font-mono);
}

/* The checkbox is a frame too, and the tick is a stroke -- the one fill left on
   the surface is 13 pixels square, and it is a mark rather than a backdrop. */
.check {
  flex: none;
  width: 13px;
  height: 13px;
  border: 1px solid currentcolor;
  transition: background var(--op-dur-fast) linear;
}

/* With no value beside it the checkbox takes the value column's job of pushing
   right -- and with neither, the mark does. Without this an arrow sits against
   the last letter of its own label, where it reads as punctuation rather than
   as the column that says this row opens a list. */
.value + .check,
.glyph + .label + .check,
.glyph + .label + .mark {
  margin-left: auto;
}

.check svg {
  display: block;
  width: 100%;
  height: 100%;
  fill: none;
  stroke: currentcolor;
  stroke-width: 2.2;
  stroke-linecap: square;
  stroke-dasharray: 13;
  stroke-dashoffset: 13;
  transition: stroke-dashoffset var(--op-dur) var(--op-ease) var(--op-dur-fast);
}

.check.ticked svg {
  stroke-dashoffset: 0;
}

/* --- ON: lit, blooming, and the one thing that leaves the plane -------------
   `.op-frame.is-on` lights the frame and the ground. What is local is the step
   out of the column: `--op-pop` across and 14px toward the player, which is
   this surface's best move and the only 3D transform on it besides the bay's
   rotation. */
.row.on {
  transform: translate3d(var(--op-pop, 10px), 0, 14px);
}

.row.on .label {
  letter-spacing: 0.055em;
  text-shadow: var(--op-ink), 0 0 10px var(--op-red-glow);
}

.row.on .value {
  opacity: 0.9;
}

.row.on .check.ticked {
  background: var(--op-red);
}

/* The one place the tick is not `currentcolor`: on the filled box it would be
   red on red, and the tick simply did not appear. `TargetView` had the answer
   for its own checkbox and this file never took it. */
.row.on .check.ticked svg {
  stroke: var(--op-ink-on);
}

/* --- a captioned separator: a mono eyebrow and a rule, no frame ----------- */
.sep {
  flex: 1;
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  min-width: 0;
  padding: var(--op-space-3) 0 var(--op-space-1) var(--op-space-1);
  color: var(--op-red-deep);
}

.slot:first-child .sep {
  padding-top: 0;
}

.sep::after {
  content: '';
  flex: 1;
  height: 1px;
  background: var(--op-red-idle);
}

/* =============================================================================
   FOOTER
   ========================================================================== */
.foot {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  min-width: 0;
  padding: var(--op-space-2) calc(var(--op-space-3) + var(--op-cut-lg))
    calc(var(--op-space-2) + var(--op-cut-lg)) calc(var(--op-space-3) + var(--op-rule));
  border-top: 1px solid var(--op-red-idle);
}

.hint {
  margin: 0;
  /* The one place the strip wraps: a description is a sentence. */
  opacity: 0.78;
}
</style>
