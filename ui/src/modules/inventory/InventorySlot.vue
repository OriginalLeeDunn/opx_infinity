<script setup lang="ts">
import { computed } from 'vue'
import { ammoOf, durabilityOf, grams, imageFor, labelOf, monogram, weightOf } from './format'
import type { CatalogEntry, ScreenConfig, Stack } from './types'

/**
 * One cell of a grid.
 *
 * It renders what it is given and emits what the player did. It never changes its
 * own count, and it never decides that a drop was legal.
 *
 * ── DESIGN PASS 02 ──────────────────────────────────────────────────────────
 *
 * NO FILL, ANYWHERE -- AND THEN ONE, ON PURPOSE. Read this paragraph and the
 * next one together; neither is true on its own. The cell used to be
 * `background: var(--op77-panel)` with a `--op77-line` border and an accent wash
 * on the drop target -- three fills in one 78px box. All three are gone, and
 * none of the three came back: a cell's STATE is still an OUTLINE and nothing
 * else, expressed in that outline's WEIGHT, its COLOUR and whether it BLOOMS.
 *
 * THE GROUND IS BACK UNDER THE OUTLINE, AND ONLY UNDER IT. The owner asked for
 * it in as many words -- "give the slots a background, and the drop one too" --
 * and it is his call to make. It is also the one place the no-fill rule was
 * actually costing something: a 50px item picture and a white stack count
 * sitting directly on a blown-out daylight plaza are unreadable however good the
 * frame around them is, and no amount of stroke fixes a picture. So a cell gets
 * a GROUND -- a dark, low-alpha plate whose entire job is to buy the ART and the
 * COUNT a backdrop.
 *
 * AND THE GROUND IS RED, which is his second instruction on it -- "for the
 * inventory backgrounds, make them red please" -- and the correct one: a cold
 * blue-black plate was the one thing on this surface belonging to no palette at
 * all, a borrowed `--op77-panel-quiet` sitting inside a red frame, and it read as
 * a hole cut in the design rather than as part of it. So the ground is the
 * surface's OWN red, taken down until it is a black: #1c0809 is `--red-idle`'s
 * rgb at 12%, #4a1519 the same rgb at 32%. Nothing else about it moved.
 *
 * RED, NOT A RED PLATE, and the difference is the whole job. The ground exists
 * so a 50px picture and a white stack count survive a blown-out street; a
 * saturated red behind them would swallow both and be worse than the no-fill
 * state this started from, because it would be a fill that pays for nothing. The
 * test every value below has to pass is that it reads as a SHADOW with a red
 * cast at a glance and only declares its hue when you look for it. That is why
 * these are 12% and 32% of a red rather than a red, and why raising them is not
 * a free hand: past roughly 40% the icons start to go.
 *
 * THIS IS NOT A LICENCE TO FILL ANYTHING ELSE. Two elements were named and two
 * elements changed: the cell here, and `.ground` in `InventoryView.vue`. The
 * panels, the tabs, the rows, the readouts, the load rules and the detail plate
 * stay unfilled, and the surface is still outlines over live gameplay. If you
 * are here to "fix" a fill back out of the pass, these two are deliberate --
 * anything else you find is not.
 *
 * TWO CHANNELS, NOT ONE LONGER LADDER. The ground does not restate the frame and
 * must not be read as another rung of it. The FRAME says what is HAPPENING to a
 * slot -- at rest, under the pointer, receiving, vacated. The GROUND says what
 * the slot IS, which is only ever one of two things. Five frames, two grounds:
 *
 *   plate    #1c0809 @ 0.78   a slot                 -- empty or occupied
 *   slab     #4a1519 @ 0.90   something is ABOUT TO BE -- the drop target
 *
 * AN EMPTY CELL USED TO BE A THIRD, HOLLOW GROUND at 0.28 with a 1px stroke at
 * 0.30, so that "an empty cell and a full one no longer read alike". The owner
 * asked for the opposite, in a sentence that covered the whole screen: the
 * buttons, the slots and the drop zone all in the menu's one style. He is right
 * about what it costs, too -- an empty slot is not a fainter kind of slot, it is
 * a slot with nothing in it, and the thing that says so is that nothing is drawn
 * in it. Spending a whole channel to restate that left a grid of forty cells
 * where the container's own edges were the palest thing on screen.
 *
 * A hovered cell still does not gain a ground: the frame has already said it and
 * a second statement would only dilute the first.
 *
 * THE TARGET USED TO BE THE ONLY WARM GROUND ON THE GRID, and that was doing the
 * work of saying "it lands here" while the other two were blue-black. Now that
 * every ground is red, warmth is a constant and cannot separate anything, so the
 * target was re-pitched onto the two channels that survive a shared hue:
 *
 *   DENSITY   0.90 against 0.78 and 0.28 -- it is the one CLOSED cell on a grid
 *             of windows, and the only one the street does not come through
 *   DEPTH     #4a1519 against #1c0809 -- the same red carried up two and a half
 *             stops toward the LIT frame standing on it, so the ground and the
 *             2.4px `--red` outline are finally saying one thing rather than a
 *             dark thing under a bright one
 *
 * which together make the receiving cell the lightest, reddest and solidest
 * thing on a surface of thin outlines, before its bloom is counted. `.ground` in
 * `InventoryView.vue` takes the SAME slab when a drag is over the drop zone, so
 * a stack about to land reads one way wherever it is about to land.
 *
 * THE GROUND FOLLOWS THE CUT, and a plain `background` is all it takes now:
 * augmented-ui clips the element, so the background IS the chamfered shape. This
 * used to be impossible -- a rectangle under a chamfered frame left a 6px
 * triangle of plate past the diagonal -- which is why the ground was painted into
 * the sprite as the path's own `fill`. The state idiom survives it: one custom
 * property moves a cell a whole step on both channels at once.
 *
 * HOW FIVE STATES READ APART IN THE OUTLINE ALONE. This ladder was carrying all
 * five of them before there was a ground beneath it and it still is: the ground
 * added a channel beside it and took nothing from it. Weight is the ordering and
 * colour is the voice; they move together, so either alone is enough to rank a
 * cell:
 *
 *   empty      1.4px   --red-idle    -- the slot exists, and that is all it says
 *   occupied   1.4px   --red-idle    -- something is in it, and the item says so
 *   hover      1.5px   --red-deep    -- denser, NOT brighter, and no bloom (the menu's hover)
 *   target     2.4px   --red         -- lit and the ONLY cell that blooms
 *
 * THE DRAGGED CELL IS NOT ON THAT RAMP, and that is the whole solve. A fifth
 * step of weight between hover and target would be indistinguishable from both
 * at 78px. So the cell the stack is being dragged OUT of does not get a heavier
 * frame -- it gets a BROKEN one: four corner brackets in `--red-hi` and no edges
 * at all. It is the only discontinuous outline on the surface, so it cannot be
 * confused with any closed frame however heavy, and the shape states exactly
 * what is true -- this slot has been vacated and is waiting to be closed again.
 * Its content drops to 0.3 opacity so the brackets are what is left.
 *
 * FOUR OF THE FIVE STATES ARE AUGMENTED, and the fifth cannot be. A colour and a
 * weight are `--aug-border-bg` and `--aug-border-all`; the DRAG state is four
 * corner brackets with no edges, which is a different shape class and not a
 * different colour, and augmented-ui's border layer is a continuous ring around
 * the clip path. So the cell's augmentation is bound rather than static: while
 * it is being dragged the element is un-augmented, unclipped, and the one
 * surviving sprite in the runtime paints its brackets whole.
 *
 * THE CUT IS 6px, which is what the old 20x20 sprite's tiles worked out to at
 * cell size. It asks for the border layer alone, so a forty-slot grid costs one
 * pseudo-element per cell rather than two.
 *
 * THE COLOURS AND THE SHADOWS ARE NOT DECLARED HERE. They are inherited, from
 * `.room` in `InventoryView.vue`, and that is the mechanism HudRoot.vue settled:
 * a scoped stylesheet cannot reach into a child component, but a CUSTOM PROPERTY
 * set on an ancestor inherits down the whole tree regardless of scoping. So the
 * ink, the separation shadow, the bloom, the resting lettering red and the
 * unfilled part of a rule are declared once on the surface and read from here --
 * one place to change the voice, and no `:deep()` anywhere.
 *
 * WHAT IS STILL LOCAL, and why the split falls where it does: the five FRAMES
 * below, because they are geometry before they are colour and the 6px tile above
 * is sized for this grid and nothing else. HudVitals.vue draws the same line --
 * it takes the palette from the root and keeps its own track.
 *
 * EVERY INHERITED VALUE CARRIES A LITERAL FALLBACK. A cell rendered outside the
 * surface -- in isolation, in a test, or by a view that has not declared the
 * palette -- still draws itself rather than drawing nothing.
 */
const props = defineProps<{
  index: number
  stack: Stack | null
  entry: CatalogEntry | undefined
  config: ScreenConfig
  /** The hotbar key drawn in the corner, for the first slots of the bag only. */
  hotkey: string
  selected: boolean
  /** The cell the pointer is currently over while a drag is in flight. */
  over: boolean
  /** This cell is the one being dragged; its frame breaks rather than moving. */
  dragging: boolean
  /** Dimmed because the active tab does not gather this item's category. */
  muted: boolean
  /** Item names whose picture has already failed to load once, surface-wide. */
  broken: Set<string>
}>()

const emit = defineEmits<{
  (event: 'grab', index: number, native: PointerEvent): void
  (event: 'open', index: number, native: MouseEvent): void
  (event: 'hover', index: number | null, native?: MouseEvent): void
  (event: 'broke', name: string): void
}>()

const label = computed(() =>
  props.stack ? labelOf(props.stack, props.entry, props.config.labels.unknown || '?') : ''
)

const image = computed(() => (props.stack ? imageFor(props.stack.name, props.entry) : ''))

const weight = computed(() =>
  props.stack
    ? grams(weightOf(props.stack, props.entry, props.config.defaultWeight), props.config)
    : ''
)

const ammo = computed(() => (props.stack ? ammoOf(props.stack) : -1))
const wear = computed(() => (props.stack ? durabilityOf(props.stack) : -1))

/* A worn item is NOT an alarm, and red is not the alarm on this surface anyway:
   a red bar inside a red frame beside a red label says nothing at all. The rule
   runs red -> lit red -> WHITE as condition falls, so the one cell in a bag that
   is nearly broken is the one carrying the only non-red mark on screen. */
const wearTone = computed(() => {
  if (wear.value < 0) return ''
  if (wear.value < 0.25) return 'spent'
  if (wear.value < 0.6) return 'worn'
  return ''
})

/** A picture that will not load is reported up once, so the monogram is drawn
    from then on for every cell holding that item rather than per cell. */
function onBroken(): void {
  if (props.stack) emit('broke', props.stack.name)
}

const showArt = computed(() => props.stack !== null && !props.broken.has(props.stack.name))
</script>

<template>
  <div
    class="cell"
    :class="{
      filled: stack !== null,
      selected,
      over,
      dragging,
      muted,
      weapon: entry?.weapon === true
    }"
    :data-augmented-ui="dragging ? undefined : 'tr-clip border'"
    :data-slot="index"
    @pointerdown.prevent="stack && emit('grab', index, $event)"
    @contextmenu.prevent="stack && emit('open', index, $event)"
    @mouseenter="emit('hover', index, $event)"
    @mouseleave="emit('hover', null)"
  >
    <span v-if="hotkey" class="key">{{ hotkey }}</span>

    <template v-if="stack">
      <span class="art">
        <img v-if="showArt" :src="image" alt="" draggable="false" @error="onBroken" />
        <span v-else class="initials">{{ monogram(label) }}</span>
      </span>

      <span v-if="stack.count > 1" class="count">{{ stack.count }}</span>
      <span v-if="ammo >= 0" class="rounds">{{ ammo }}</span>

      <span v-if="wear >= 0" class="wear" :class="wearTone">
        <i :style="{ width: `${wear * 100}%` }" />
      </span>

      <span class="foot">
        <span class="name op-truncate">{{ label }}</span>
        <span class="mass">{{ weight }}</span>
      </span>
    </template>
  </div>
</template>

<style scoped>
/* =============================================================================
   THE ONE SPRITE LEFT IN THE RUNTIME -- the DRAG state, four corner brackets and
   no edges.

   It survives because it is a SHAPE and not a colour: augmented-ui draws a
   continuous ring around the clip path and cannot open four gaps in it. Every
   stroke lives inside a corner tile, because anything drawn outside one lands in
   a stretched edge slice and tiles down the whole side. The top-right bracket IS
   the chamfer, which keeps the broken frame the same shape as the closed one.

   Its ground is the HOLLOW one, and that is not a compromise: a vacated slot is
   about to be empty, so it stands on what an empty slot stands on. It is a
   SEPARATE unstroked path ahead of the bracket group -- the brackets are four
   open strokes and a fill on those would close four shapes meant to stay open.
   ========================================================================== */
.cell {
  --cell-drag: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><path d="M0.5 0.5H13.5L19.5 6.5V19.5H0.5Z" fill="none" stroke="%23000" stroke-opacity="0.8" stroke-width="3.5"/><path d="M0.5 0.5H13.5L19.5 6.5V19.5H0.5Z" fill="%231c0809" fill-opacity="0.28" stroke="none"/><g fill="none" stroke="%23ff6b78" stroke-width="1.6"><path d="M0.5 5.5V0.5H5.5"/><path d="M13.5 0.5L19.5 6.5"/><path d="M19.5 13.5V19.5H13.5"/><path d="M0.5 14.5V19.5H5.5"/></g></svg>');

  position: relative;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  box-sizing: border-box;
  height: 100%;
  padding: var(--op-space-1);
  color: var(--op-red-idle);
  /* THE INK STAYS, and the ground does not make it redundant: the plate is a
     low-alpha wash and not an opaque panel, so a glyph in a cell is still half
     on the street. They do different jobs at different scales -- the plate buys
     a 50px PICTURE its contrast, which no text-shadow can, and the ink buys a
     9px LETTER its edge, which no 0.78 wash can.
     One declaration: `text-shadow` inherits, so the count, the rounds, the name
     and the mass all take it from here -- and the value itself comes from the
     surface, so the grid and the panel around it are in the same ink. */
  text-shadow: var(--ink, 0 1px 2px rgba(0, 0, 0, 0.95), 0 0 9px rgba(0, 0, 0, 0.8));
  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: rgba(var(--op-red-idle-rgb), 0.70);
  background: var(--op-plate);
  /* THE BLACK IS IN THE SPRITE, and this is where it stopped being a box-shadow.

     It was an outset `var(--dark)` on the cell box, and the comment here argued
     that being "square where the frame is chamfered... at this blur reads as the
     corner darkening rather than as a second shape". It does not: the owner
     picked it out on sight, on these cells and on every other chamfered element
     in the runtime. An outset shadow follows the BORDER BOX, so it repaints
     exactly the corner the chamfer just cut and squares it back up.

     Every `--cell-*` sprite now carries a wide black under-stroke on the same
     path as the red one, so the separation follows the diagonal by construction.
     3.5 rather than the 4.5 the full-size frames take: a cell's
     `border-image-width` is 6px against a 20px sprite, so its stroke is already
     being scaled up relative to theirs.

     The drop target's bloom stays a `box-shadow`: a wide blur has no edge for
     the chamfer to disagree with. */
  /* The whole grid is one scroll container; a cell must not be a drag source for
     the browser's own drag, which fights the pointer tracking. */
  user-select: none;
  touch-action: none;
  /* IT CUTS, IT DOES NOT FADE. `border-image-source` is not an animatable
     property, which is exactly right here: the frame swaps on the frame the
     state changes. Only the two continuous values transition. */
  transition:
    color var(--op-dur-fast) linear,
    opacity var(--op-dur-fast) linear;
}

.cell.filled {
  color: var(--op-red-text);
  --aug-border-bg: rgba(var(--op-red-idle-rgb), 0.70);
  cursor: grab;
}

/* --- HOVER: denser red, heavier stroke, no bloom -------------------------- */
.cell.filled:hover:not(.over):not(.dragging) {
  color: var(--op-red-deep);
  --aug-border-bg: var(--op-red-deep);
  --aug-border-all: 1.5px;
}

/* --- TARGET: lit, heaviest, and the one thing on the grid that blooms -----
   `selected` rides the same frame: Lua sends 0 for it today, and a cell the
   runtime has chosen and a cell the pointer is over mean the same thing to the
   eye -- this is where the stack lands. */
.cell.over,
.cell.selected {
  color: var(--op-red);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2.4px;
  background: var(--op-plate-lit);
  /* A `drop-shadow` AND NOT A `box-shadow`, which is forced by the clip: an
     outset shadow is sheared along the chamfer. The old note here refused a
     filter because "forty of them" would each take a backing store -- but only
     ONE cell is the drop target at a time, and it changes when the pointer moves
     between cells rather than on a clock. */
  filter: drop-shadow(0 0 6px var(--op-red-glow));
}

/* --- DRAGGED: the frame BREAKS. ------------------------------------------
   Not a step on the weight ramp -- a different shape class, so it reads apart
   from hover and from the target no matter which of them is also on screen. The
   dark shadow goes with the edges: there is no closed box left to separate. */
.cell.dragging,
.cell.dragging:hover {
  color: var(--op-red-hi);
  /* The drag state is the one that still needs a sprite: see the header. */
  border: 1px solid transparent;
  border-image-source: var(--cell-drag);
  border-image-slice: 6 fill;
  border-image-width: 6px;
  box-shadow: none;
  cursor: grabbing;
}

/* What is left in a vacated slot is the brackets. */
.cell.dragging .art,
.cell.dragging .count,
.cell.dragging .rounds,
.cell.dragging .wear,
.cell.dragging .foot {
  opacity: 0.3;
}

/* A cell whose item the active tab does not gather. It keeps its frame -- the
   slot is still there and still a legal drop -- and loses its content. */
.cell.muted {
  opacity: 0.26;
}

/* =============================================================================
   WHAT IS IN A CELL
   ========================================================================== */

/* The hotbar cap. Mono, in the frame's own colour, so it restates on hover and
   on the target without a declaration of its own. */
.key {
  position: absolute;
  top: 3px;
  left: 5px;
  font: 700 var(--op-fs-micro) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: currentcolor;
  opacity: 0.6;
}

.cell.filled .key {
  opacity: 1;
}

.art {
  position: absolute;
  inset: 13px 7px 26px;
  display: flex;
  align-items: center;
  justify-content: center;
  pointer-events: none;
  transition: opacity var(--op-dur-fast) linear;
}

/* No drop-shadow on the picture: a `filter` is allowed on an icon and this is a
   50px image, forty of them in a window. The items ship with their own contrast. */
.art img {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
}

/* The fallback when a picture will not load. Display face, the cell's colour. */
.initials {
  font: 700 var(--op-fs-title) / 1 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  color: currentcolor;
  opacity: 0.75;
}

.cell.weapon .initials {
  opacity: 1;
}

/* The stack count reads WHITE and the rounds read red: two numbers in the same
   corner region of the same cell, and the only way to tell them apart with no
   fill behind either is for them not to be the same colour. White is also the
   honest choice for the count -- it is the one number here that is not a
   property of the frame's state. */
.count {
  position: absolute;
  top: 3px;
  right: 6px;
  font: 700 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: var(--op-text);
  font-variant-numeric: tabular-nums;
  transition: opacity var(--op-dur-fast) linear;
}

.rounds {
  position: absolute;
  right: 6px;
  bottom: 24px;
  font: 700 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: currentcolor;
  font-variant-numeric: tabular-nums;
  transition: opacity var(--op-dur-fast) linear;
}

/* The condition rule. Two pixels of stroke, which is what the menu's separator
   is: a rule, not a fill. It is also the only mark in a cell that carries no
   text-shadow, because it carries no text -- and it carries a READING, so losing
   it over a blown-out plaza loses information rather than structure. It gets the
   tight dark pass as a box-shadow. The 1px structural hairlines elsewhere on the
   surface deliberately do not: they say where things are, not what they are.

   IT IS NOT DIVIDED, and the two load rules on the panels are. The notches there
   are a 1px mask on a 4px bar; this one is 2px tall inside a 90px square, so ten
   divisions of it would be a dotted line rather than a count -- and there is
   nothing to count anyway. A load is a quantity the player is managing and reads
   off in steps; condition is a state, and what it has to say is which of the
   three colours it is. Same object, two sizes, one of them below the size at
   which a division means anything. */
.wear {
  position: absolute;
  left: 5px;
  right: 5px;
  bottom: 22px;
  height: 2px;
  background: var(--red-track, rgba(var(--op-red-idle-rgb), 0.22));
  box-shadow: var(--ink-tight, 0 1px 2px rgba(0, 0, 0, 0.95));
  transition: opacity var(--op-dur-fast) linear;
}

.wear i {
  display: block;
  height: 100%;
  background: var(--op-red-idle);
}

.wear.worn i {
  background: var(--op-red-hi);
}

/* SPENT READS WHITE, and heavier, for the same reason a failure does: red is the
   voice of this whole surface, so red cannot also be the alarm. It is the SAME
   hot rung `.room` calls `--red-hot` and the load rule's `full` state uses, and
   it was the one colour in this file still spelling that rung out by hand. */
.wear.spent i {
  background: var(--op-alarm);
}

.foot {
  display: flex;
  align-items: baseline;
  gap: var(--op-space-1);
  min-width: 0;
  pointer-events: none;
  transition: opacity var(--op-dur-fast) linear;
}

.name {
  flex: 1 1 auto;
  font: 400 var(--op-fs-micro) / 1.2 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: currentcolor;
}

.cell.filled:hover .name,
.cell.over .name,
.cell.selected .name {
  color: var(--op-text);
}

.mass {
  flex: none;
  font: 400 var(--op-fs-micro) / 1.2 var(--op-font-mono);
  color: currentcolor;
  opacity: 0.75;
  font-variant-numeric: tabular-nums;
}
</style>
