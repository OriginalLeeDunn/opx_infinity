<script setup lang="ts">
import { shallowRef } from 'vue'
import { num, text, records } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'
import { iconPaths } from './icons'

/**
 * THE VITALS COLUMN -- health, armour, stamina, hunger, thirst.
 *
 * THE ONE HOT CHANNEL ON THIS SURFACE. `opx:hud:vitals` is a numeric stream at roughly
 * the surface's 30 Hz, and the store is a `shallowRef` REPLACED WHOLESALE for exactly
 * that reason: `ref([])` over five rows of five fields is twenty-five reactive
 * dependencies re-validated thirty times a second to move five numbers, and Vue's deep
 * proxy would be walking a fresh array of fresh objects on every frame to discover that
 * all of it is new. One dependency, one assignment, one render.
 *
 * Nothing below decides what is low. `tone` arrives decided: Lua holds the thresholds
 * because Lua holds the configuration, and a page that coloured its own gauge would be
 * a second opinion about the player's health.
 *
 * -- DESIGN PASS 02 -----------------------------------------------------------
 *
 * THE GAUGE IS DRAWN HERE NOW. It was `OpGauge`, and OpGauge is shared with the voice
 * meter, the panel module and anything else that grows a meter -- so changing it changes
 * surfaces nobody has looked at yet. This folder carries its own while the pass is being
 * settled, exactly as MenuView.vue carries its own frame and row, and for the same
 * reason: a duplicate nobody has agreed to keep is the cheapest thing to delete.
 *
 * WHAT CHANGED INSIDE IT, and both changes are performance before they are style:
 *
 *   1. TWENTY SEGMENTS BECAME ONE BAR. A gauge's fill is DATA, so it is the one filled
 *      shape the contract leaves standing -- but its track and its frame are outlines.
 *      The segment count Lua configures did not go anywhere: it is drawn as hairline
 *      graduations ON the track, one static gradient, instead of as N live boxes.
 *      OpGauge changed `background` on up to twenty leaf nodes per gauge per frame;
 *      five gauges at 30 Hz is three thousand fill repaints a second to move five
 *      numbers.
 *   2. THE BAR MOVES BY `transform`, never by `width`. `scaleX` on a composited layer
 *      costs no layout and no repaint at all; a `width` in percent costs both, on the
 *      hottest element of the hottest channel on the surface. This is the single
 *      biggest saving in the folder.
 */
const { t } = useLocale()

withDefaults(defineProps<{ segments?: number; width?: number }>(), {
  segments: 10,
  width: 210
})

type Tone = 'neutral' | 'health' | 'warn' | 'bad'

const TONES: readonly string[] = ['neutral', 'health', 'warn', 'bad']

interface Vital {
  id: string
  icon: string[]
  label: string
  value: number
  /** The pool in POINTS when the source keeps one, else null. See below. */
  points: number | null
  tone: Tone
}

const vitals = shallowRef<Vital[]>([])

function toneOf(value: unknown): Tone {
  const name = text(value, 'neutral')
  return TONES.indexOf(name) === -1 ? 'neutral' : (name as Tone)
}

/** 0..1, for the fill's `scaleX`. Clamped here because a stream is a stream. */
function share(value: number): number {
  return Math.max(0, Math.min(100, value)) / 100
}

/** The `aria-valuenow`: the SHARE, which is what the bar is and what 0..100 means. */
function shown(value: number): number {
  return Math.round(Math.max(0, Math.min(100, value)))
}

/**
 * The read-out. POINTS when Lua sent them, the share when it did not.
 *
 * THE OWNER, on a full player: "le hud affiche 100 enfois de 250 dans vie". The
 * number was the percent and it was correct and it was useless -- while the
 * maximum was 100 the percent and the points were the same number and nobody had
 * to decide which this was, and at 250 they part. The bar stays a share because a
 * bar is a share; the number says how much health there is.
 *
 * Armour arrives as a percent and the needs are percentages by definition, so
 * they send no points and keep the number they always had.
 */
function readout(vital: Vital): number {
  return vital.points === null ? shown(vital.value) : vital.points
}

useBridge('opx:hud:vitals', (payload: Payload) => {
  // `list()` and not `payload.gauges || []`: an empty Lua table is `{}`, which is truthy,
  // and `{}.map` is the throw the bridge would swallow -- at 30 Hz, silently, forever.
  vitals.value = records(payload.gauges)
    .filter((row) => text(row.id) !== '')
    .map((row) => ({
      id: text(row.id),
      icon: iconPaths(text(row.icon)),
// The KEY, translated where it is drawn: Lua sends each payload once (deduped by
      // signature), so one that beat the locale catalogue would otherwise keep the raw
      // key on screen until the value next changed. `t()` in the template is reactive.
      label: text(row.label),
      value: num(row.pct),
      // `num` answers 0 for an absent field, and 0 points is a real reading -- a
      // dying player. The absence has to survive as an absence, so it is tested
      // before it is converted.
      points: row.points === undefined || row.points === null ? null : num(row.points),
      tone: toneOf(row.tone)
    }))
})
</script>

<template>
  <div class="vitals" :style="{ '--vitals-width': width + 'px', '--segs': segments }">
    <!-- KEYED BY ID, and the key is what makes the entrance work: a gauge that survives
         a frame keeps its element, so the stutter-in below runs once when the vital
         first appears and never again while the stream is running. -->
    <div
      v-for="vital in vitals"
      :key="vital.id"
      class="gauge"
      :class="vital.tone"
      role="meter"
      :aria-valuenow="shown(vital.value)"
      :aria-valuemin="0"
      :aria-valuemax="100"
      :aria-label="t(vital.label)"
    >
      <span class="glyph" aria-hidden="true">
        <svg v-if="vital.icon.length" viewBox="0 0 16 16" aria-hidden="true">
          <path v-for="(d, index) in vital.icon" :key="index" :d="d" />
        </svg>
      </span>

      <!-- THE TRACK IS THE FRAME. One chamfered 1px outline with the graduations on it,
           and the bar inside it inset by 3px so its square top-right corner lands
           exactly on the chamfer's diagonal instead of poking through it. -->
      <!-- `.bar` EXISTS ONLY TO CARRY THE CUT, and it has to be its own element.
           A `clip-path` on `.fill` would be scaled by the `scaleX` that moves the
           bar -- the corner would stretch open as the gauge fills and close as it
           empties. The clip belongs on a box that never transforms. -->
      <span class="track" data-augmented-ui="tr-clip border">
        <span class="bar">
          <span class="fill" :style="{ transform: `scaleX(${share(vital.value)})` }" />
        </span>
      </span>

      <span class="readout">{{ readout(vital) }}</span>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   THE COLUMN -- the plane that tilts. `.at` in HudRoot.vue is the positioned
   wrapper and holds the perspective, the paint containment and the sign; this
   is the surface that rotates in it, pivoting on whichever screen edge Lua
   anchored the column to.
   ========================================================================== */
.vitals {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-2);
  width: var(--vitals-width, 210px);
  max-width: calc(100vw - var(--op-inset-x) * 2);
  /* NO GROUND, and no padding with it. A plate went behind this column and came
     straight back off on the owner's word, with the rest of the HUD's: the
     padding only existed to stop the plate reading as a highlighter, and
     `WIDTH` in `config/hud.lua` means the column again rather than the column
     plus its inset. */
  transform-origin: var(--origin, left center);
  transform: rotateY(var(--tilt, 0deg));
}

/* NO ENCLOSING PANEL, and no interlace either. The interlace is what stops an
   unfilled FRAME reading as a web page floating in the air -- there is no frame
   here to put it on, and drawing a striped rectangle around five gauges would
   invent the panel this column has never had. The gauges carry themselves. */
.gauge {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  /* Every tone resolves through these two, so a state change is exactly two
     custom properties and the browser repaints one bar and one number. */
  --tone: var(--op-red-idle);
  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: var(--op-red-idle);
  color: var(--tone);
}

.glyph {
  flex: none;
  width: 14px;
  height: 14px;
}

.glyph svg {
  display: block;
  width: 100%;
  height: 100%;
  fill: none;
  stroke: currentcolor;
  stroke-width: 1.6;
  stroke-linecap: round;
  stroke-linejoin: round;
  /* An SVG stroke takes no text-shadow, so the contract's answer is one
     drop-shadow -- and this is the only `filter` in THIS file. It is allowed
     because it is STATIC: a 14px glyph whose paint changes only when Lua
     changes the tone, at most five on screen. Nothing whose value moves every
     frame carries one, which is why the bar, the readout and the vehicle rings
     do not.

     IT IS NOT THE ONLY ONE IN THE FOLDER, which is what this used to claim.
     `HudVoice.vue` has two -- the mic glyph's black, static for the same reason
     as this one, and the rx counter's bloom, which `shapes.css` allows because
     an outset shadow is sheared by a clip and the counter changes only when the
     set of speakers does. Both are argued where they are written. A false
     invariant is worse than none: the next reader trusts it and stops looking. */
  filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.95));
  transition: stroke var(--op-dur-fast) linear;
}

.track {
  position: relative;
  box-sizing: border-box;
  flex: 1;
  min-width: 0;
  height: 16px;
  /* 3px of inset on every side is the bar's clearance from the frame, and it is
     measured rather than chosen: the chamfer cuts 6px off the top-right corner,
     so a bar held 3px from the top and 3px from the right ends exactly on the
     diagonal. Without it the bar at 100% shows a square corner inside a cut
     frame -- and the alternative, clipping the bar, is a `clip-path` on the one
     element that changes every frame. */
  padding: 3px;
}

/* THE GRADUATIONS. Lua's segment count, drawn as hairlines on the track instead
   of as N live boxes -- a line, not a fill, and one static gradient for the
   life of the gauge however often the bar moves. `to left` puts each tick on
   the trailing edge of its cell, so the count reads as N divisions and not as
   N+1 rules. */
.track::after {
  content: "";
  position: absolute;
  inset: 3px;
  pointer-events: none;
  background-image: linear-gradient(to left, var(--op-red-idle) 0 1px, transparent 1px);
  background-size: calc(100% / var(--segs, 10)) 100%;
}

/* THE ONE FILLED SHAPE ON THE HUD, and it is data: a quantity has to have an
   area or it is not a quantity. `transform-origin: left` and `scaleX` -- never
   `width` -- so the 30 Hz stream is a composited transform and not a relayout.
   No shadow and no bloom on it: both would scale with the bar. */
/* THE BAR TAKES THE TRACK'S CORNER. The note on `.track` said the 3px inset was
   enough -- that a square top-right corner "lands exactly on the chamfer's
   diagonal instead of poking through it" -- and at 100% it does not: the bar is
   a rectangle inside a cut frame, so the one thing that is actually FILLED on
   the HUD was the one thing still square. It carries the cut itself now.

   5px, not the frame's 8px: the diagonal runs at 45 degrees and this box sits
   3px inside the border box, so the cut it meets there is 8 - 3 = 5.

   Static, so it costs one clip for the life of the gauge however fast the bar
   moves -- and it is on THIS box rather than on `.fill` precisely so the
   transform never touches it. */
.bar {
  display: block;
  width: 100%;
  height: 100%;
  clip-path: polygon(0 0, calc(100% - 5px) 0, 100% 5px, 100% 100%, 0 100%);
}

.fill {
  display: block;
  width: 100%;
  height: 100%;
  background: var(--tone);
  transform-origin: left center;
  transform: scaleX(0);
  transition:
    transform var(--op-dur-fast) linear,
    background var(--op-dur-fast) linear;
}

.readout {
  flex: none;
  min-width: 22px;
  text-align: right;
  font: 700 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  font-variant-numeric: tabular-nums;
  transition: color var(--op-dur-fast) linear;
}

/* --- THE TONES, and the ladder is luminance ------------------------------
   `neutral` and `health` are the resting and the lit red; `warn` is the
   brightest red the surface owns; `bad` LEAVES THE HUE. See the block comment
   in HudRoot.vue: red is this surface's voice, so the alarm cannot also be red,
   and a bar that goes white-hot with a white frame and a heavier readout is the
   only thing here that cannot be read as the HUD talking about itself. */
.health {
  --tone: var(--op-red);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2px;
}

.warn {
  --tone: var(--op-red-hi);
  --aug-border-bg: var(--op-red-hi);
  --aug-border-all: 2px;
}

.bad {
  --tone: var(--op-alarm);
  --aug-border-bg: var(--op-alarm);
  --aug-border-all: 2.6px;
}

.bad .readout {
  font-weight: 700;
}

/* =============================================================================
   THE BOOT-IN -- a stutter, not a fade, and one shot per gauge. `opacity` and
   `transform` only, which the compositor runs without a repaint. `backwards`
   holds frame zero through the stagger delay so a gauge does not flash at full
   opacity before its turn.
   ========================================================================== */
@keyframes vital-in {
  0% {
    opacity: 0;
    transform: translate3d(-8px, 0, 0);
  }

  55% {
    opacity: 1;
    transform: translate3d(2px, 0, 0);
  }

  100% {
    opacity: 1;
    transform: translate3d(0, 0, 0);
  }
}

.gauge {
  animation: vital-in var(--op-enter-ms) var(--op-stutter) backwards;
  /* NO STAGGER, on the owner's word: rows land together, as the menu's buttons and
     the eye's rows do. A per-row delay read as the rows trickling in. */
}
</style>
