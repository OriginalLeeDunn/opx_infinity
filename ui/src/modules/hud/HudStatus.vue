<script setup lang="ts">
import { onUnmounted, shallowRef } from 'vue'
import { guard } from '@/bridge/diag'
import { num, text, records, own } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE STATUS STRIP -- bleeding, burning, netrunning, whatever else the status source
 * publishes. This surface draws them and owns none of them.
 *
 * THE STRIP IS UNTRUSTED INPUT. The client's local bus is shared with every resource on
 * the host, so the original bounded everything in Lua before it reached the page: at most
 * MAX_CHIPS, no id means dropped, the overflow count clamped. The page repeated those
 * bounds rather than trusting its sender, and so does this.
 *
 * The countdown is the page's own arithmetic. `remainingMs` arrives as a DURATION and is
 * turned into a deadline here, on arrival, exactly as hud.js did: the two clocks then
 * never have to agree, and a frame that took 40ms to arrive does not make the chip run
 * 40ms long. `remainingMs` is also deliberately not part of Lua's frame signature -- a
 * counter ticking down is not a new image, and the page animates it alone.
 *
 * -- DESIGN PASS 02 -----------------------------------------------------------
 *
 * THE CHIP IS DRAWN HERE NOW. It was `OpChip`, which is `.op-tag` plus
 * `data-augmented-ui="tr-clip"` plus a `--op77-panel` fill -- all three banned on this
 * surface -- and it is shared with the admin staff tags, so it could not simply be
 * changed. A chip is now a chamfered 1px frame with nothing behind it.
 *
 * THE COUNTDOWN MOVES BY `transform`. It was a `width` in percent rewritten every 50ms,
 * which is a layout and a paint twenty times a second per timed chip; `scaleX` on the
 * same bar is a composited transform and costs neither. The 20 Hz timer itself is
 * unchanged, including the 0.002 dead band that stops it writing when nothing moved.
 */
const { t } = useLocale()

/** hud.js MAX_CHIPS. The +N overflow chip does not count against it. */
const MAX_CHIPS = 12
/** The largest `+N` that still reads as a number. */
const MAX_HIDDEN = 999
/** 20 Hz: the underline is 2px tall and this is not the vitals stream. */
const TICK_MS = 50

type Tone = 'neutral' | 'accent' | 'ok' | 'warn' | 'bad' | 'shock'

/**
 * The Cyberpunk damage types hud.css drew separately collapse onto the three tones that
 * already meant the same thing. `shock` is still carried across the bridge and still has
 * its own name here -- the payload contract has not changed -- but it no longer has its
 * own COLOUR: see the tone block in the stylesheet.
 */
const TONES: Record<string, Tone> = {
  neutral: 'neutral',
  accent: 'accent',
  ok: 'ok',
  warn: 'warn',
  bad: 'bad',
  shock: 'shock',
  bleed: 'bad',
  burn: 'warn',
  chem: 'ok'
}

interface Chip {
  id: string
  icon: string
  label: string
  tone: Tone
  /** Epoch ms, or 0 when this chip is not counting down. */
  endsAt: number
  /** The lifetime the remainder is drawn against; 0 when there is none. */
  totalMs: number
  /** 0..1, or -1 for "draw no underline". */
  progress: number
}

const chips = shallowRef<Chip[]>([])
const hidden = shallowRef(0)

let timer: ReturnType<typeof setInterval> | undefined

useBridge('opx:hud:status', (payload: Payload) => {
  const atMs = Date.now()
  const seen = new Set<string>()
  const next: Chip[] = []

  for (const row of records(payload.chips)) {
    if (next.length >= MAX_CHIPS) break
    const id = text(row.id)
    if (!id || seen.has(id)) continue
    seen.add(id)

    const remainingMs = num(row.remainingMs)
    const totalMs = num(row.totalMs)
    const timed = remainingMs > 0 && totalMs > 0
    // A static share, for an effect with a level rather than a lifetime.
    const fixed = typeof row.progress === 'number' ? Math.max(0, Math.min(1, row.progress)) : -1

    next.push({
      id,
      icon: text(row.icon).slice(0, 4),
// The KEY, translated where it is drawn: Lua sends each payload once (deduped by
      // signature), so one that beat the locale catalogue would otherwise keep the raw
      // key on screen until the value next changed. `t()` in the template is reactive.
      label: text(row.label),
      tone: own(TONES, text(row.tone, 'neutral')) ?? 'neutral',
      endsAt: timed ? atMs + remainingMs : 0,
      totalMs: timed ? totalMs : 0,
      progress: timed ? Math.max(0, Math.min(1, remainingMs / totalMs)) : fixed
    })
  }

  chips.value = next
  hidden.value = Math.max(0, Math.min(MAX_HIDDEN, Math.round(num(payload.hidden))))
  pump()
})

function tick(): void {
  const atMs = Date.now()
  let running = false
  let changed = false

  const next = chips.value.map((chip) => {
    if (chip.endsAt === 0) return chip
    const left = Math.max(0, Math.min(1, (chip.endsAt - atMs) / chip.totalMs))
    if (left > 0) running = true
    if (Math.abs(left - chip.progress) < 0.002) return chip
    changed = true
    return { ...chip, progress: left }
  })

  if (changed) chips.value = next
  // Nothing is removed at zero: the chip leaves when the status source stops sending it,
  // and an empty underline under a chip that is still real is the truth.
  if (!running) stop()
}

function pump(): void {
  if (timer !== undefined) return
  if (!chips.value.some((chip) => chip.endsAt > 0)) return
  // Outside a bridge handler, so channel.ts is not above this to catch a throw.
  timer = setInterval(() => guard('hud status tick', tick, undefined), TICK_MS)
}

function stop(): void {
  if (timer === undefined) return
  clearInterval(timer)
  timer = undefined
}

onUnmounted(stop)
</script>

<template>
  <div v-if="chips.length" class="strip">
    <span
      v-for="chip in chips"
      :key="chip.id"
      class="chip"
      data-augmented-ui="tr-clip border"
      :class="chip.tone"
    >
      <span v-if="chip.icon" class="icon">{{ chip.icon }}</span>
      <span class="label">{{ t(chip.label) }}</span>
      <!-- The remainder. A filled bar, and legitimate for the same reason a gauge's is:
           it is the quantity itself, not a backdrop for one. -->
      <span
        v-if="chip.progress >= 0"
        class="time"
        :style="{ transform: `scaleX(${Math.max(0, Math.min(1, chip.progress))})` }"
      />
    </span>

    <!-- What did not fit, counted rather than dropped -- and true, which is the only
         reason a micro-label is allowed to be on this surface at all. -->
    <!-- NOT augmented, and it is the one chip that is not: the overflow count is
         square and dashed on purpose, because the house shape is what says "this
         is one of the things above" and a count is not one of them. -->
    <span
      v-if="hidden > 0"
      class="chip overflow"
    >
      <span class="label">+{{ hidden }}</span>
    </span>
  </div>
</template>

<style scoped>
/* =============================================================================
   THE STRIP -- the plane that tilts. `.at` in HudRoot.vue holds the perspective,
   the paint containment and the sign; this rotates in it, pivoting on the screen
   edge Lua anchored the strip to.
   ========================================================================== */
.strip {
  display: flex;
  flex-wrap: wrap;
  gap: var(--op-space-2);
  max-width: calc(100vw - var(--op-inset-x) * 2);
  transform-origin: var(--origin, left center);
  transform: rotateY(var(--tilt, 0deg));
}

/* =============================================================================
   A CHIP -- a closed 1px frame with a chamfered top-right corner, and text.
   Nothing behind it. The cut is `--op-cut-sm`, a token rather than a sprite
   scaled down by its slice, so a chip and a menu row are the same shape at two
   sizes rather than two drawings that have to be kept in step.
   ========================================================================== */
.chip {
  position: relative;
  --aug-tr: var(--op-cut-sm);
  display: inline-flex;
  align-items: center;
  gap: var(--op-space-2);
  padding: 5px var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-sm));
  font: 700 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  white-space: nowrap;
  --tone: var(--op-red-idle);
  --aug-border-bg: var(--op-red-idle);
  color: var(--tone);
  /* NO GROUND. A plate went under these chips and came straight back off on the
     owner's word: the HUD is the one surface that keeps the pass's no-fill rule,
     because it is never read for long and a row of filled pills along the bottom
     of the screen is a toolbar. The ink shadow inherited from HudRoot.vue is what
     holds a chip against a bright street, and it is enough at chip size. */
  transition: color var(--op-dur-fast) linear;
}

/* The icon is a few characters Lua chose, not a glyph set, so it is type and it
   takes the inherited ink shadow like everything else. */
.icon {
  flex: none;
  font: 900 var(--op-fs-meta) / 1 var(--op-font-mono);
}

.time {
  position: absolute;
  left: 0;
  bottom: 0;
  width: 100%;
  height: 2px;
  background: var(--tone);
  /* `scaleX` and not `width`: at 20 Hz per timed chip, a percentage width is a
     layout and a paint each tick and this is neither. */
  transform-origin: left center;
  transform: scaleX(0);
  transition: transform var(--op-dur-fast) linear;
}

/* --- THE TONES -----------------------------------------------------------
   Four rungs of red and then out of it, the same ladder the gauges use:

       neutral  --red-idle   a chip that is simply present
       ok       --red-deep   benign, denser but not lit
       accent   --red        lit: the HUD is pointing at this one
       warn     --red-hi     the brightest red on the surface
       bad      --alarm      white-hot, and heavier with it

   `shock` FOLDS ONTO THE WARN RUNG. It was the one colour in the whole design
   system with no token behind it -- a cold #7fb4ff, kept because it names a
   damage type rather than a UI role -- and on a HUD that is now one hue from
   edge to edge a single cold blue chip does not read as a damage type, it reads
   as a rendering fault. The chip's own icon and label already say SHOCK, which
   is the part a player actually reads. The tone name still crosses the bridge
   and still has a rule here, so restoring the blue is one declaration. */
.ok {
  --tone: var(--op-red-deep);
}

.accent {
  --tone: var(--op-red);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2px;
}

.warn,
.shock {
  --tone: var(--op-red-hi);
  --aug-border-bg: var(--op-red-hi);
  --aug-border-all: 2px;
}

/* A chip is already 700, so `bad` cannot get heavier -- the white and the
   heavier frame stroke are the whole of its state, which is the reference's
   rule for a chosen row applied to an alarming one. */
.bad {
  --tone: var(--op-alarm);
  --aug-border-bg: var(--op-alarm);
  --aug-border-all: 2.6px;
}

/* Square and hairline-dashed on purpose, and the only chip with no chamfer: the
   overflow chip is a COUNT, not a status, and the house shape is what says
   "this is one of the things above". */
.chip.overflow {
  padding-right: var(--op-space-3);
  color: var(--op-text-faint);
  border: 1px dashed var(--op-red-idle);

}

/* =============================================================================
   THE BOOT-IN -- a stutter, one shot. The v-for is keyed by the status id, so a
   chip that survives a frame keeps its element and does not re-run it; a chip
   the status source has just raised does.
   ========================================================================== */
@keyframes chip-in {
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

.chip {
  animation: chip-in var(--op-enter-ms) var(--op-stutter) backwards;
  /* NO STAGGER, on the owner's word: rows land together, as the menu's buttons and
     the eye's rows do. A per-row delay read as the rows trickling in. */
}
</style>
