<script setup lang="ts">
import { computed, shallowRef } from 'vue'
import { text, records } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'
import type { Anchor } from './anchors'
import { railOf } from './anchors'

/**
 * THE READ-OUT -- money, job, street cred, and anything else Lua decides to name.
 *
 * `buildMoney` and `buildIdentity` in `opx77_hud/client/state.lua` decide which lines
 * exist, in which order, and with which tone; this draws them. It has no idea what a
 * currency is.
 *
 * -- DESIGN PASS 02 -----------------------------------------------------------
 *
 * THIS IS THE ONE CLUSTER ON THE HUD THAT IS A FRAME, so it is the one that draws one.
 * It was an `OpPanel`: an augmented element with `--op77-panel` at 0.94 alpha behind it
 * and the `op-rail` house marker down its leading edge. All three are gone. The frame is
 * now two opposite chamfers cut with `clip-path` and a 1px red outline drawn as an INSET
 * shadow, which is the one place a clip and a stroke can live together -- an inset shadow
 * is painted over the padding box, so the clip trims it to the chamfer instead of
 * shearing an outset one off the element.
 *
 * THE BACKING IS GONE AND THE SHADOW IS BACK. The pass-01 note in this file said the
 * panel is what made the read-out legible "so the shadow is gone with it". There is no
 * panel now, so the double `text-shadow` returns -- once, on `.hud` in HudRoot.vue, where
 * it is inherited by this file and the other four.
 *
 * `--op77-hud-veil` is the escape hatch, the same dial the menu carries under its own
 * name: 0 by default, raised to about 0.5 if a column of numbers washes out over a
 * daylight plaza. One number to reverse the decision instead of a rewrite.
 */
const { t } = useLocale()

const props = withDefaults(defineProps<{ anchor?: Anchor }>(), { anchor: 'top-right' })

type Tone = 'neutral' | 'on' | 'warn' | 'bad'

const TONES: readonly string[] = ['neutral', 'on', 'warn', 'bad']

interface Line {
  id: string
  label: string
  value: string
  tone: Tone
}

const lines = shallowRef<Line[]>([])

/** Which screen edge is the leading one. A right-anchored panel reads the right edge as
    its lead, so the chamfers, the arete and the column of numbers all mirror. */
const end = computed(() => railOf(props.anchor) === 'end')

function toneOf(value: unknown): Tone {
  const name = text(value, 'neutral')
  return TONES.indexOf(name) === -1 ? 'neutral' : (name as Tone)
}

useBridge('opx:hud:info', (payload: Payload) => {
  lines.value = records(payload.lines)
    .filter((row) => text(row.id) !== '')
    .map((row) => ({
      id: text(row.id),
// The KEY, translated where it is drawn: Lua sends each payload once (deduped by
      // signature), so one that beat the locale catalogue would otherwise keep the raw
      // key on screen until the value next changed. `t()` in the template is reactive.
      label: text(row.label),
      // Already formatted by Lua: separators, currency symbols and rounding are all
      // decisions, and a page that formatted a number would be making one.
      value: text(row.value),
      tone: toneOf(row.tone)
    }))
})
</script>

<template>
  <section v-if="lines.length" class="info" :class="end ? 'to-end' : 'to-start'">
    <div class="inner">
      <div
        v-for="line in lines"
        :key="line.id"
        class="line"
        :class="line.tone"
      >
        <span class="label">{{ t(line.label) }}</span>
        <span v-if="line.value" class="value">{{ line.value }}</span>
      </div>
    </div>
  </section>
</template>

<style scoped>
/* =============================================================================
   THE FRAME -- no fill. It is also the plane that tilts: `.at` in HudRoot.vue is
   the positioned wrapper and holds the perspective, the paint containment and
   the sign, and this rotates in it about whichever edge it is anchored to.
   ========================================================================== */
.info {
  min-width: 180px;
  max-width: 34vw;
  /* NO ENCLOSURE. It had a chamfered frame with an inset outline; the old
     `opx77_hud` drew none, and neither does this now. A HUD block is an
     INSTRUMENT sitting on the gameplay plane, not a panel: the three clusters
     that never had a box read correctly without one, and boxing these two made
     them the odd pair out. The tilt, the type, the reds and the shadows stay --
     only the container loses its edges. */
  transform-origin: var(--origin, right center);
  transform: rotateY(var(--tilt, 0deg));
}

/* `.info.to-end` mirrored the chamfers and the arete. With no enclosure there
   is nothing left for it to mirror -- the tilt already follows the anchor. */

.inner {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  min-width: 0;
  /* NO GROUND. A plate went here and came straight back off on the owner's word.
     The argument for it -- that money and identity are looked AT rather than
     glanced at -- was a reason to fill the one HUD block that had padding ready,
     and the answer in game was that it made a panel of the HUD's corner. The ink
     shadow on `.hud` carries these lines, as it carries the other four blocks. */
  padding: var(--op-space-3) calc(var(--op-space-3) + var(--op-cut-lg))
    calc(var(--op-space-3) + var(--op-cut-lg) * 0.5) calc(var(--op-space-3) + var(--op-rule));
}

.to-end .inner {
  padding: var(--op-space-3) calc(var(--op-space-3) + var(--op-rule))
    calc(var(--op-space-3) + var(--op-cut-lg) * 0.5)
    calc(var(--op-space-3) + var(--op-cut-lg));
}

/* THE INTERLACE. One static gradient on a pseudo-element nothing else was using,
   no transition, so it costs a single paint for the life of the block -- and it
   is what stops an unfilled frame reading as a web page floating in the air.
   This cluster and the voice block are the only two that get it, because they
   are the only two with a frame to put it on. */
/* The interlace went with the frame, for the reason given in HudVoice.vue. */

/* THE EYEBROW IS GONE. It captioned the read-out `STATUS` above a money line
   that already says what it is, and `payload.eyebrow` is simply no longer read.
   Lua may keep sending it; nothing here draws it. */

.line {
  display: flex;
  align-items: baseline;
  gap: var(--op-space-3);
  font: 400 var(--op-fs-meta) / 1.3 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  white-space: nowrap;
}

/* Right-anchored: the value lands on the edge the block is pinned to, so a
   column of numbers reads down the outside instead of down the middle. */
.to-end .line {
  justify-content: space-between;
}

.label {
  color: var(--op-red-idle);
}

.value {
  margin-left: auto;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  color: var(--op-red);
}

/* --- THE TONES -----------------------------------------------------------
   `on` -- the job line on duty -- is the reference's own answer for a state
   that matters: it does NOT change hue, it goes lit and it BLOOMS, and that is
   the whole of it. The bloom restates both black passes because a `text-shadow`
   override replaces the entire list and this surface has no backing to lose.

   `warn` takes the brightest red, and `bad` leaves the hue for white-hot and
   700. See HudRoot.vue: red is the voice of this HUD, so it cannot be the
   alarm as well. */
.on .value {
  color: var(--op-red);
  text-shadow:
    0 1px 2px rgba(0, 0, 0, 0.95),
    0 0 9px rgba(0, 0, 0, 0.8),
    0 0 10px var(--op-red-glow);
}

.warn .value {
  color: var(--op-red-hi);
}

.bad .value {
  color: var(--op-alarm);
  font-weight: 700;
}

/* =============================================================================
   THE BOOT-IN -- a stutter, one shot per line, keyed by Lua's line id so a line
   that survives a frame does not re-run it. The money line changes its VALUE
   many times a session and its identity almost never, which is exactly the case
   a keyed v-for gets right.
   ========================================================================== */
@keyframes line-in {
  0% {
    opacity: 0;
    transform: translate3d(6px, 0, 0);
  }

  55% {
    opacity: 1;
    transform: translate3d(-2px, 0, 0);
  }

  100% {
    opacity: 1;
    transform: translate3d(0, 0, 0);
  }
}

.line {
  animation: line-in var(--op-enter-ms) var(--op-stutter) backwards;
  /* NO STAGGER, on the owner's word: rows land together, as the menu's buttons and
     the eye's rows do. A per-row delay read as the rows trickling in. */
  animation-delay: 40ms;
}

/* A left-anchored read-out arrives from its own edge. */
.to-start .line {
  animation-name: line-in-start;
}

@keyframes line-in-start {
  0% {
    opacity: 0;
    transform: translate3d(-6px, 0, 0);
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
</style>
