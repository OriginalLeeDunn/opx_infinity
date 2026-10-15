<script setup lang="ts">
import { computed, onMounted, ref, shallowRef } from 'vue'
import { emit } from '@/bridge/channel'
import { list, num, text, records } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE KEY STRIP -- the port of `opx77_prompts/web/{index.html,prompts.js,prompts.css}`.
 *
 * It decides nothing, exactly as prompts.js decided nothing. Order, the cut to the row
 * budget and every key NAME arrive resolved: a cap says what the player's own binding
 * says, and this page has no keyboard layout to map a scancode with.
 *
 * ── DESIGN PASS 02 ──────────────────────────────────────────────────────────
 *
 * A PROMPT IS A LINE, NOT A BOX. It was an `OpPanel` per group holding padded rows: an
 * augmented frame, a header with a bottom rule, a body with inner padding, and a
 * `--op77-accent-soft` fill under every keycap. All of that is gone. What is left is
 * one inline row -- the key, then what it does -- and nothing drawn around it.
 *
 * NO ENCLOSURE, and this is now the house rule rather than a local choice: HudInfo.vue
 * and HudVoice.vue made the same call, the ALT target and the inventory after them, and
 * the pre-rebuild `opx77_prompts` drew no enclosure either. A prompt is the most
 * transient thing on the screen -- it appears because the player walked up to a door --
 * and a framed panel says "drive me", which is exactly what a prompt is not.
 *
 * THE INTERLACE DOES NOT SURVIVE, for the reason spelled out in HudVoice.vue: it exists
 * to stop an unfilled FRAME reading as a web page floating in the air, and with no frame
 * a striped rectangle IS that floating rectangle. The strip has no bounds of its own now,
 * so there is nothing to stripe -- only lines, and each one is lifted off the street by
 * the black ink shadow instead.
 *
 * THE KEYCAP KEEPS ITS EDGE, and it is the only thing here that does. It is a control,
 * and it depicts a physical key: a key with no edge is a word, and `E OPEN` is two words
 * where `[E] OPEN` is an instruction. So the cap takes the house 9-slice frame -- the same
 * sprite MenuView.vue and the HUD draw -- and nothing else does. `OpKeyCap` could not
 * survive that: it is `data-augmented-ui` plus an `--op77-accent-soft` fill plus a 2px
 * accent under-rule, and a bottom rule 2px thick IS a fill however thin. The weighted
 * base goes with it, so a held key no longer reads as a heavier cap -- see below, the
 * hold tag went the same way.
 *
 * THE HOLD TAG IS GONE. Lua still sends `hold` per row and `prompts.hold` in the config,
 * and this page no longer reads either: a word beside the cap saying HOLD was a caption
 * on a keycap, and the owner called it what it was. The Lua contract is untouched -- the
 * field is validated, change-gated and sent exactly as before, and drawn by nobody, the
 * same standing as `payload.eyebrow` in HudInfo.vue.
 */
const { t } = useLocale()

type Anchor = 'bottom-right' | 'bottom-left' | 'top-right' | 'top-left'

/** Closed set: an unrecognised anchor falls back rather than reaching a class name. */
const ANCHORS: readonly string[] = ['bottom-right', 'bottom-left', 'top-right', 'top-left']

/** The page's own ceilings, repeating Lua's rather than trusting the sender for them. */
const MAX_GROUPS = 32
const MAX_ROWS = 24
const MAX_CAPS = 6

interface Cap {
  /** Stable within a row, so a rebind swaps the label without remounting the cap. */
  key: string
  label: string
  /** The `+` that says these two are pressed together. Never on the first cap. */
  join: boolean
}

interface Row {
  key: string
  caps: Cap[]
  label: string
  value: string
  dim: boolean
}

interface Group {
  key: string
  title: string
  rows: Row[]
}

const groups = shallowRef<Group[]>([])
const anchor = ref<Anchor>('bottom-right')
const offset = ref(0)
const maxWidth = ref(420)
/** prompts.js `hide()`: hidden, never emptied -- the next frame usually says the same. */
const hidden = ref(false)

function capsOf(row: Payload): Cap[] {
  const combo = row.combo === true
  return list(row.caps)
    .slice(0, MAX_CAPS)
    .map((cap, index) => ({
      key: `${index}:${text(cap)}`,
      label: text(cap),
      join: combo && index > 0
    }))
}

useBridge('opx:prompts:config', (payload: Payload) => {
  const wanted = text(payload.anchor)
  if (ANCHORS.indexOf(wanted) !== -1) anchor.value = wanted as Anchor

  const clear = num(payload.offset, -1)
  if (clear >= 0) offset.value = Math.round(clear)

  const width = num(payload.maxWidth)
  if (width > 0) maxWidth.value = Math.round(width)

  // `payload.hold` -- the localised word HOLD -- still arrives and is no longer read.
})

useBridge('opx:prompts:frame', (payload: Payload) => {
  const seenGroups = new Set<string>()
  const next: Group[] = []
  // One budget across the whole frame, not per group: the strip is bounded by the screen
  // it sits on, and eight groups of eight rows is a wall, not a hint.
  let rowBudget = MAX_ROWS

  for (const raw of records(payload.groups)) {
    if (next.length >= MAX_GROUPS || rowBudget <= 0) break
    const key = text(raw.key)
    if (!key || seenGroups.has(key)) continue

    const seenRows = new Set<string>()
    const rows: Row[] = []
    for (const rawRow of records(raw.rows)) {
      if (rowBudget <= 0) break
      const rowKey = text(rawRow.key)
      if (!rowKey || seenRows.has(rowKey)) continue
      const caps = capsOf(rawRow)
      // A prompt with no key to name says nothing. Lua drops these too; the page repeats
      // the rule because the bus it listens on is shared with every other resource.
      if (caps.length === 0) continue
      seenRows.add(rowKey)
      rows.push({
        key: rowKey,
        caps,
        // Keys, translated in the template: a frame that beat the catalogue kept the
        // raw key until the next frame that changed. `t()` there is reactive.
        label: text(rawRow.label),
        value: text(rawRow.value),
        // `rawRow.hold` is deliberately not read: nothing draws it any more.
        dim: rawRow.dim === true
      })
      rowBudget -= 1
    }
    // An empty group is a title and no information.
    if (rows.length === 0) continue

    seenGroups.add(key)
    next.push({ key, title: text(raw.title), rows })
  }

  groups.value = next
  hidden.value = false
})

useBridge('opx:prompts:hide', () => {
  hidden.value = true
})

/**
 * NOTHING IS PUBLISHED ABOUT THE CORNER ANY MORE. The strip used to measure what it held
 * of the bottom-right corner so the voice block pinned there could step up out of its
 * way. That corner is the game's round minimap now (opx_sandy_view 1.4.18) and the voice
 * indicator is a row of the vitals column, so nothing reads a hold: the strip clears the
 * map by its own `OFFSET` (`config/prompts.lua`).
 */
const open = computed(() => groups.value.length > 0 && !hidden.value)

onMounted(() => {
  emit('opx:prompts:ready', {})
})
</script>

<template>
  <div class="prompts">
    <div
      class="strip"
      :class="[anchor, { open }]"
      :style="{ '--strip-offset': offset + 'px', '--strip-width': maxWidth + 'px' }"
    >
      <!-- A GROUP IS NOT A PANEL. It is a title and its lines: no frame, no header rule,
           no body padding. It is still the element that TILTS, because the plane a line
           sits on is the group's, not each row's -- one rotation per group instead of
           one per row. -->
      <div v-for="group in groups" :key="group.key" class="group">
        <div v-if="group.title" class="title op-truncate">{{ t(group.title) }}</div>

        <div
          v-for="row in group.rows"
          :key="row.key"
          class="row"
          :class="{ dim: row.dim }"
        >
          <span class="caps">
            <span v-for="cap in row.caps" :key="cap.key" class="key">
              <span v-if="cap.join" class="join">+</span>
              <kbd class="cap op-cap" data-augmented-ui="tr-clip border">{{ cap.label }}</kbd>
            </span>
          </span>
          <span class="label op-truncate">{{ t(row.label) }}</span>
          <span v-if="row.value" class="value">{{ row.value }}</span>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   DESIGN PASS 02 -- A PROMPT IS A LINE.

   Read MenuView.vue's `<style scoped>` first: it is the agreed reference and this
   copies its idiom. What this surface does NOT take from it is the enclosure --
   the menu is a thing the player drives and a control is a closed frame; a prompt
   is a thing the player is told, and it sits loose on the gameplay plane like the
   rest of the HUD.

   WHAT A LINE COSTS. Per row: no fill, no filter, no frame on the row itself.
   One augmented keycap, whose shape is CSS and whose whole state is one custom
   property. The strip's entire paint is the type and the caps.
   ========================================================================== */

.prompts {
  position: absolute;
  inset: 0;
}

/* ACROSS, NOT DOWN. Prompts are a strip of things the player can do right now,
   and a column of them is a list to be read; a line of them is a toolbar to be
   glanced at. `wrap` is the only concession: past the viewport a second line is
   better than a prompt nobody can see. */
.strip {
  position: fixed;
  box-sizing: border-box;
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  align-items: center;
  /* Wider across than down: the gap between two GROUPS has to out-read the gap
     between two rows inside one, and across that is the only separation left. */
  gap: var(--op-space-2) var(--op-space-5);
  width: auto;
  max-width: calc(100vw - var(--op-inset-x) * 2 + var(--op-bleed) * 2);
  padding: var(--op-bleed);

  /* THE PLANE IS TILTED, and this is the wrapper that carries the perspective:
     perspective on the group itself would give every descendant its own vanishing
     point. */
  perspective: var(--op-persp);
  /* Nothing inside can affect layout or paint outside it, so the compositor never
     has to consider the rest of the screen when one prompt arrives. */
  contain: layout paint style;

  /* THE ONE INK SHADOW FOR THE WHOLE STRIP. There is no backing of any kind now, so
     every glyph sits directly on whatever the street is doing -- and a text-shadow
     INHERITS, so this single declaration carries every title, every cap, every label
     and every reading. It is the honest fix for an unbacked line: it darkens the two
     pixels around a letter instead of putting a box behind the row.

     Two passes, not one: the tight dark pass gives an edge its contrast, the wide
     soft pass lifts the line off a blown-out daylight plaza. */
  text-shadow:
    0 1px 2px rgba(0, 0, 0, 0.95),
    0 0 9px rgba(0, 0, 0, 0.8);

  /* Opacity and transform, never `display`: a node taken out of layout replays its
     entrance when it comes back, and the strip is hidden and shown constantly --
     every time the chat composer takes the keyboard. It CUTS, it does not fade. */
  opacity: 0;
  transform: translateY(var(--slide, 8px));
  transition:
    opacity var(--op-enter-ms) var(--op-stutter),
    transform var(--op-enter-ms) var(--op-stutter);
}

.strip.open {
  opacity: 1;
  transform: none;
}

/* A RIGHT-anchored surface gets -7deg and pivots on the right edge. */
.bottom-right,
.top-right {
  right: calc(var(--op-inset-x) - var(--op-bleed));
  align-items: flex-end;
  --tilt: calc(var(--op-tilt) * -1);
  --origin: right center;
  --from: 6px;
}

/* A LEFT-anchored one gets +7deg and pivots on the left. */
.bottom-left,
.top-left {
  left: calc(var(--op-inset-x) - var(--op-bleed));
  align-items: flex-start;
  --tilt: var(--op-tilt);
  --origin: left center;
  --from: -6px;
}

/* Bottom anchors grow upward: the first group, the highest priority, sits nearest the
   edge. The frame arrives in priority order and the column is reversed here, so nothing
   in script has to know which way the strip grows. */
.bottom-right,
.bottom-left {
  bottom: calc(var(--op-inset-y) - var(--op-bleed) + var(--strip-offset, 0px));
  --slide: 8px;
}

/* A line pinned to the right edge has to grow leftward, which is `justify-content`
   now rather than the `column-reverse` a stack used -- reversing a ROW would also
   reverse the reading order, and these are read left to right whatever edge they
   are pinned to. */
.bottom-right,
.top-right {
  justify-content: flex-end;
}

.bottom-left,
.top-left {
  justify-content: flex-start;
}

.top-right,
.top-left {
  top: calc(var(--op-inset-y) - var(--op-bleed) + var(--strip-offset, 0px));
  --slide: -8px;
}

/* =============================================================================
   A GROUP -- a title and its lines. No frame, no fill, no padding, and the plane
   that rotates.
   ========================================================================== */
.group {
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  align-items: center;
  gap: var(--op-space-1) var(--op-space-4);
  max-width: 100%;
  min-width: 0;
  /* THE GROUND, on the group and not on the row. A row here is one line as wide
     as its words -- key, verb, reading -- and plating each of them separately
     would draw a ragged staircase of rectangles down the edge of the screen. The
     group is the shape a player actually sees, so it is the shape that gets a
     floor, and the padding is what stops the floor reading as a highlighter. */
  padding: var(--op-space-2) var(--op-space-3);
  background: var(--op-plate);
  transform-origin: var(--origin, right center);
  transform: rotateY(var(--tilt, 0deg));
}

/* THE INTERLACE DOES NOT SURVIVE. It is rule 9 of the contract and it is there to
   stop an unfilled FRAME reading as a page floating in the air -- with no frame, a
   striped rectangle IS that floating rectangle, and the rectangle it would stripe
   is not even a shape this surface owns: it is the bounding box of a handful of
   lines of different lengths. Same call, same reason, as HudVoice.vue. The black
   ink shadow on `.strip` is what lifts a line off the street now. */

/* A real caption on a real group, so rule 8 is satisfied without inventing filler:
   the title is what Lua named the group, localised. */
.title {
  font: 700 var(--op-fs-micro) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  text-transform: uppercase;
  color: var(--op-red-idle);
}

/* =============================================================================
   A ROW -- ONE LINE: the key, then what it does, then the reading if there is one.
   Nothing encloses it. No padding, no border, no background, and it is as wide as
   its words.
   ========================================================================== */
.row {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  min-width: 0;
  white-space: nowrap;
}

.caps {
  flex: none;
  display: flex;
  align-items: center;
  gap: 3px;
}

.key {
  display: inline-flex;
  align-items: center;
  gap: 3px;
}

/* Between two caps pressed together. Alternatives and sequences have no joiner. */
.join {
  font: 700 var(--op-fs-meta) / 1 var(--op-font-mono);
  color: var(--op-red-idle);
}

/* THE ONE DRAWN EDGE ON THIS SURFACE. A keycap is a control and it depicts a
   physical key, so it keeps the house frame at cap size while everything around it
   loses its box. No fill and no weighted base: the shared `OpKeyCap` built its whole
   idiom on `inset 0 -2px` going to `-4px` on a hold, and a 2px bottom rule is a fill
   -- which is rule 1, and which HudVoice.vue already dropped for the same reason. */
.cap {
  flex: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  box-sizing: border-box;
  min-width: 24px;
  height: 22px;
  padding: 0 7px;
  /* The chamfer lives in the top-right corner, so the right side pays for it. */
  padding-right: calc(7px + var(--op-cut-sm));
  font: 700 var(--op-fs-meta) / 1 var(--op-font-mono);
  letter-spacing: 0.04em;
  color: var(--op-red);
}

/* What the key does. `--op-text` is LEGIBILITY and nothing else on this surface:
   it carries no state and says nothing about the prompt, it is simply the words the
   player has to read at a glance while something is happening to them. The red is
   spent on the cap, which is the part that is an instrument. */
.label {
  flex: 0 1 auto;
  font: 700 var(--op-fs-lead) / 1.2 var(--op-font-display);
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--op-text);
}

/* A live reading beside the label -- the noclip speed is the one in the tree. THE
   HAIRLINE IS GONE with every other line on this surface: it separated two things
   that a gap separates. */
.value {
  flex: none;
  margin-left: auto;
  padding-left: var(--op-space-2);
  font: 700 var(--op-fs-meta) / 1.2 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  /* Not upper-cased: a unit is data, and "M/S" is not metres per second. */
  color: var(--op-red);
  font-variant-numeric: tabular-nums;
}

/* --- UNAVAILABLE FOR NOW --------------------------------------------------
   The absence of a state, not a rung of the ladder, so it leaves the hue: the cap
   takes the off frame and every glyph on the line goes to the faint grey. There is
   no plate left to drop, which is what the old note here worried about -- a row
   that lost its plate read as a row that had left. A row that goes grey reads as a
   row that is still there and cannot be used, which is the truth. */
.dim .cap {
  color: var(--op-text-faint);
  --aug-border-bg: var(--op-off-line);
}

.dim .label,
.dim .value,
.dim .join {
  color: var(--op-text-faint);
}

/* =============================================================================
   THE BOOT-IN -- a stutter, not a fade, one shot per line and keyed by Lua's row
   id, so a row that survives a frame does not re-run it. That matters here more
   than anywhere: the noclip speed row is re-sent every time the speed changes and
   keeps its identity throughout, which is exactly the case a keyed v-for gets
   right. Both keyframes touch `opacity` and `transform` only.
   ========================================================================== */
@keyframes prompt-in {
  0% {
    opacity: 0;
    transform: translate3d(var(--from, 6px), 0, 0);
  }

  55% {
    opacity: 1;
    transform: translate3d(calc(var(--from, 6px) * -0.34), 0, 0);
  }

  100% {
    opacity: 1;
    transform: translate3d(0, 0, 0);
  }
}

.strip.open .row {
  animation: prompt-in var(--op-enter-ms) var(--op-stutter) backwards;
  /* NO STAGGER, on the owner's word: rows land together, as the menu's buttons and
     the eye's rows do. A per-row delay read as the rows trickling in. */
  animation-delay: 40ms;
}
</style>
