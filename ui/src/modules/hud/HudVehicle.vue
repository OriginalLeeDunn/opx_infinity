<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, shallowRef, watch } from 'vue'
import { holdBottomCenter } from '@/stores/corners'
import { num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE VEHICLE DIAL -- shown only while Lua says the character is sitting in one.
 *
 * Outer ring: engine speed, white past the redline. Inner ring: integrity. The gear sits
 * in the dial's open bottom, between the ring's two ends.
 *
 * WHY THIS IS STILL AN SVG AND NOT A ROW OF GAUGES. A speedometer is the one read-out on
 * this HUD that is not a quantity in a list -- it is a quantity you glance at without
 * reading, which is what a radial does and what a bar does not. There is no radial in the
 * design system and this is the only caller for one, so it stays module art: two
 * `stroke-dasharray` writes on two leaf paths, which is the cheap case.
 *
 * `rpm` and `integrity` are OPTIONAL and their absence is not zero. A vehicle whose engine
 * speed is not reported fills the outer ring from road speed instead, and one whose
 * integrity is not reported draws no inner ring and no integrity line at all: an empty
 * integrity ring is a thing a player brakes for.
 *
 * `fuel` IS OPTIONAL ON THE SAME TERMS. Cyberpunk has no tank; the fuel module keeps one on
 * the vehicle's state bag, and a car nobody has filled -- or a server without the module --
 * draws no fuel line at all rather than an empty gauge a player would pull over for. It is
 * a line under the dial and not a third ring: the dial is speed, and a tank is read the way
 * integrity is, as a share with a word in front of it.
 *
 * -- DESIGN PASS 02 -----------------------------------------------------------
 *
 * THE RING IS AN OUTLINED CHANNEL WITH A FILL IN IT. It was a grey band (a fill) with a
 * coloured band drawn over it. Now two hairline rails bound an empty channel and the
 * engine's share is the only painted band between them -- the same division the bar
 * gauges make, in polar coordinates: the track and the frame are outlines, the fill is
 * data.
 *
 * THE BLACK UNDER THE RINGS IS A PATH, NOT A FILTER. Everything on this HUD carries a
 * black shadow and an SVG stroke cannot take a text-shadow, so the contract's answer is
 * `filter: drop-shadow`. Not here: these two rings have their `stroke-dasharray`
 * rewritten on every frame the car is moving, and a filter on an element that changes
 * every frame is a backing store re-rasterised every frame. So the shadow is an extra
 * path under each ring, one stroke wider and black -- a paint the compositor already had
 * to do, instead of a filter it did not.
 *
 * THE GEAR BADGE IS AN OUTLINE. It was `background: var(--op77-accent)` with ink text on
 * it, which on this surface is both a fill and a yellow.
 */
const { t } = useLocale()

/** Past this share of the outer ring the engine reads as redlining. hud.js REDLINE. */
const REDLINE = 85
/** Road speed that fills the outer ring when engine speed is not reported. hud.js DIAL_KPH. */
const DIAL_KPH = 250

/**
 * The arcs, all struck from (60,60) and all opening 90deg at the bottom, so an endpoint is
 * (60 -/+ R/sqrt2, 60 + R/sqrt2). `pathLength="100"` on every one of them, so a percentage
 * is a dash length and nothing here has to know a circumference.
 *
 *   OUTER / INNER  the two bands, at r=52 and r=44 -- the fills and their shadows.
 *   RAIL_*         the outer band's edges, at r=55.5 and r=48.5: the channel the engine's
 *                  share is painted into, and the only reason it reads as a frame rather
 *                  than as a stripe floating on the screen.
 */
const OUTER = 'M23.2 96.8A52 52 0 1 1 96.8 96.8'
const INNER = 'M29 91A44 44 0 1 1 91 91'
const RAIL_OUT = 'M20.7 99.3A55.5 55.5 0 1 1 99.3 99.3'
const RAIL_IN = 'M25.7 94.3A48.5 48.5 0 1 1 94.3 94.3'

type Tone = 'neutral' | 'warn' | 'bad'

const TONES: readonly string[] = ['neutral', 'warn', 'bad']

interface Vehicle {
  active: boolean
  speed: number
  unit: string
  gear: string
  /** -1 when the engine speed is not reported. */
  rpm: number
  /** -1 when integrity is not reported, which is not the same as 0. */
  integrity: number
  integrityLabel: string
  tone: Tone
  airborne: string
  /** -1 when the vehicle has no tank this server measures, which is not the same as 0. */
  fuel: number
  fuelLabel: string
  fuelTone: Tone
}

const EMPTY: Vehicle = {
  active: false,
  speed: 0,
  unit: '',
  gear: 'N',
  rpm: -1,
  integrity: -1,
  integrityLabel: '',
  tone: 'neutral',
  airborne: '',
  fuel: -1,
  fuelLabel: '',
  fuelTone: 'neutral'
}

const vehicle = shallowRef<Vehicle>(EMPTY)

useBridge('opx:hud:vehicle', (payload: Payload) => {
  if (payload.active !== true) {
    vehicle.value = { ...vehicle.value, active: false }
    return
  }

  const tone = text(payload.tone, 'neutral')
  const fuelTone = text(payload.fuelTone, 'neutral')
  vehicle.value = {
    active: true,
    speed: Math.max(0, Math.round(num(payload.speed))),
    unit: text(payload.unit),
    gear: text(payload.gear, 'N') || 'N',
    // `typeof` and not `num`: 0 rpm is a real reading and -1 has to mean "not reported".
    rpm: typeof payload.rpm === 'number' ? Math.max(0, Math.min(100, payload.rpm)) : -1,
    integrity:
      typeof payload.integrity === 'number' ? Math.max(0, Math.min(100, payload.integrity)) : -1,
    integrityLabel: t(text(payload.integrityLabel)),
    tone: (TONES.indexOf(tone) === -1 ? 'neutral' : tone) as Tone,
    airborne: payload.airborne === true ? t(text(payload.airborneLabel)) : '',
    // `typeof` again: an empty tank is 0, and -1 means there is no tank to read.
    fuel: typeof payload.fuel === 'number' ? Math.max(0, Math.min(100, payload.fuel)) : -1,
    fuelLabel: t(text(payload.fuelLabel)),
    fuelTone: (TONES.indexOf(fuelTone) === -1 ? 'neutral' : fuelTone) as Tone
  }
})

const outerFill = computed(() => {
  const value = vehicle.value
  const share = value.rpm >= 0 ? value.rpm : (value.speed / DIAL_KPH) * 100
  return Math.max(0, Math.min(100, share))
})

/**
 * WHAT THE DIAL HOLDS OF THE BOTTOM EDGE, published for the hotbar peek. Both default to
 * the bottom centre, and a peek while driving was drawn straight over the dial.
 *
 * MEASURED off the positioned wrapper (`.at` in HudRoot.vue), which is laid out whether
 * or not the dial is showing and never transitions -- so the number is the dial's place,
 * not a frame of its entrance. Published only while the car is live and only when the
 * wrapper actually crosses the middle of the screen: a dial an operator anchored to a
 * corner holds nothing the peek needs. The wrapper's own bleed is the gap between them.
 */
const root = ref<HTMLElement | null>(null)
/** Half the peek's width, near enough: five 72px cells and their gaps. */
const PEEK_HALF = 200
let sizer: ResizeObserver | null = null

function publish(): void {
  const wrapper = root.value?.parentElement
  if (!vehicle.value.active || !wrapper) {
    holdBottomCenter(0)
    return
  }
  const box = wrapper.getBoundingClientRect()
  const middle = window.innerWidth / 2
  const crosses = box.left < middle + PEEK_HALF && box.right > middle - PEEK_HALF
  const low = box.bottom > window.innerHeight / 2
  holdBottomCenter(crosses && low ? window.innerHeight - box.top : 0)
}

watch(() => vehicle.value.active, publish, { flush: 'post' })

onMounted(() => {
  window.addEventListener('resize', publish)
  if (root.value && typeof ResizeObserver !== 'undefined') {
    sizer = new ResizeObserver(publish)
    sizer.observe(root.value)
  }
})

onBeforeUnmount(() => {
  window.removeEventListener('resize', publish)
  sizer?.disconnect()
  sizer = null
  holdBottomCenter(0)
})

const redlining = computed(() => vehicle.value.rpm >= REDLINE)

const gearClass = computed(() => {
  const gear = vehicle.value.gear
  if (gear === 'R') return 'reverse'
  if (gear === 'N') return 'idle'
  return 'drive'
})
</script>

<template>
  <div ref="root" class="vehicle" :class="{ live: vehicle.active, hot: redlining }">
    <div class="dial">
      <svg class="rings" viewBox="0 0 120 120" aria-hidden="true">
        <!-- The black, as geometry. One stroke wider than the band it sits under. -->
        <path class="shade" :d="OUTER" pathLength="100" />
        <!-- The channel: two hairlines, which is the track AND the frame. -->
        <path class="rail" :d="RAIL_OUT" pathLength="100" />
        <path class="rail" :d="RAIL_IN" pathLength="100" />
        <!-- The last stretch of the rim, marked before the band reaches it. White,
             because on this HUD the alarm is the one thing that is not red. -->
        <path class="redline" :d="RAIL_OUT" pathLength="100" />
        <path
          class="rpm"
          :d="OUTER"
          pathLength="100"
          :style="{ strokeDasharray: outerFill + ' 100' }"
        />

        <template v-if="vehicle.integrity >= 0">
          <path class="shade-in" :d="INNER" pathLength="100" />
          <path class="inner-track" :d="INNER" pathLength="100" />
          <path
            class="integrity"
            :class="vehicle.tone"
            :d="INNER"
            pathLength="100"
            :style="{ strokeDasharray: vehicle.integrity + ' 100' }"
          />
        </template>
      </svg>

      <div class="core">
        <span class="speed">{{ vehicle.speed }}</span>
        <span v-if="vehicle.unit" class="unit">{{ vehicle.unit }}</span>
      </div>
      <span class="gear" :class="gearClass" data-augmented-ui="tr-clip border">{{ vehicle.gear }}</span>
    </div>

    <div class="meta">
      <span v-if="vehicle.integrity >= 0" class="integrity-row" :class="vehicle.tone">
        <span class="label">{{ vehicle.integrityLabel }}</span>
        <b>{{ Math.round(vehicle.integrity) }}%</b>
      </span>
      <span v-if="vehicle.fuel >= 0" class="fuel-row" :class="vehicle.fuelTone">
        <span class="label">{{ vehicle.fuelLabel }}</span>
        <span class="fuel-track"><span class="fuel-fill" :style="{ width: vehicle.fuel + '%' }" /></span>
        <b>{{ Math.round(vehicle.fuel) }}%</b>
      </span>
      <span v-if="vehicle.airborne" class="chip" data-augmented-ui="tr-clip border">
        <span class="chip-icon">!</span>
        <span class="chip-label">{{ vehicle.airborne }}</span>
      </span>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   THE BLOCK. `.at` in HudRoot.vue holds the perspective, the paint containment
   and the tilt sign; this is the plane that rotates in it.

   BY DEFAULT IT DOES NOT ROTATE AT ALL. `vehicleAnchor` is `bottom-center` and a
   centred cluster gets no tilt, which for this one cluster is a relief as well as
   the rule: 7deg of rotateY turns a circular dial into an ellipse. If Lua anchors
   the dial to a screen edge it tilts with everything else and the rings go
   elliptical -- the contract is one plane per edge, not one plane per shape, and
   a dial exempted from it would be the only thing on the HUD facing the player
   square on.
   ========================================================================== */
.vehicle {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: var(--op-space-1);
  opacity: 0;
  transform-origin: var(--origin, center center);
  transform: rotateY(var(--tilt, 0deg)) translateY(8px);
  /* An entrance, so it stutters in three steps rather than fading. */
  transition:
    opacity var(--op-enter-ms) var(--op-stutter),
    transform var(--op-enter-ms) var(--op-stutter);
}

.vehicle.live {
  opacity: 1;
  transform: rotateY(var(--tilt, 0deg)) translateY(0);
}

.dial {
  position: relative;
  width: 112px;
  height: 112px;
}

.rings {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  fill: none;
  stroke-linecap: butt;
  /* NO `filter` ANYWHERE ON THIS ELEMENT. Two of its paths have their dash
     rewritten on every frame the car is moving; a filter here is a backing store
     re-rasterised at the same rate. The black is the `.shade` paths instead. */
}

/* The shadow, as geometry: the same arc, one stroke wider, black. */
.shade {
  stroke: rgba(0, 0, 0, 0.55);
  stroke-width: 9;
}

.shade-in {
  stroke: rgba(0, 0, 0, 0.55);
  stroke-width: 4.5;
}

/* The channel the engine's share is painted into. Hairlines -- an outline, not a
   band, so an empty dial reads as an empty instrument and not as a grey stripe. */
.rail {
  stroke: var(--op-red-idle);
  stroke-width: 1.2;
}

.inner-track {
  stroke: var(--op-red-idle);
  stroke-width: 1.2;
}

/* The redline zone, marked on the rim. White at low alpha: the alarm on this HUD
   is the absence of red, and a red warning band on a red ring says nothing. */
.redline {
  stroke: var(--op-alarm);
  stroke-opacity: 0.32;
  stroke-width: 2;
  stroke-dasharray: 15 100;
  stroke-dashoffset: -85;
}

/* THE FILLS. The one painted area per ring, and it is the quantity itself. Both
   change `stroke-dasharray` and nothing else -- no width, no filter, no fill. */
.rpm {
  stroke: var(--op-red);
  stroke-width: 6;
  stroke-dasharray: 0 100;
  transition:
    stroke-dasharray var(--op-dur-fast) linear,
    stroke var(--op-dur-fast) linear;
}

/* Redlining is the one moment the dial is telling the player about damage rather
   than about speed, so the band leaves the hue exactly as a `bad` gauge does. */
.hot .rpm {
  stroke: var(--op-alarm);
}

.integrity {
  /* Denser, not lit: integrity is the second read-out on this dial and the
     engine band is the first. */
  stroke: var(--op-red-deep);
  stroke-width: 2.5;
  stroke-dasharray: 0 100;
  transition:
    stroke-dasharray var(--op-dur-fast) linear,
    stroke var(--op-dur-fast) linear;
}

.integrity.warn {
  stroke: var(--op-red-hi);
}

.integrity.bad {
  stroke: var(--op-alarm);
}

.core {
  position: absolute;
  inset: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 2px;
}

.speed {
  font: 700 var(--op-fs-head) / 1 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  color: var(--op-red);
  font-variant-numeric: tabular-nums;
  transition: color var(--op-dur-fast) linear;
}

/* The number goes to the brightest red rather than to white: the white is spent
   on the band, and two white things on one dial is an instrument with two
   alarms. */
.hot .speed {
  color: var(--op-red-hi);
}

.unit {
  font: 700 var(--op-fs-micro) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: var(--op-red-idle);
}

/* =============================================================================
   THE GEAR -- in the dial's open bottom, between the ring's ends. An outline,
   chamfered at 5px: the same shape as everything else, at the size this one is.
   ========================================================================== */
.gear {
  position: absolute;
  bottom: 6px;
  left: 50%;
  transform: translateX(-50%);
  min-width: 20px;
  padding: 3px 5px 2px;
  font: 700 var(--op-fs-meta) / 1 var(--op-font-mono);
  text-align: center;
  color: var(--op-red);
  --aug-tr: calc(var(--op-cut-sm) - 1px);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2px;
}

/* Neutral is the quiet rung: the car is in gear for nothing. */
.gear.idle {
  color: var(--op-red-idle);
  --aug-border-bg: var(--op-red-idle);
  --aug-border-all: 1px;
}

/* Reverse is not an alarm, so it is not white -- it is the brightest red, the
   same rung a `warn` gauge takes. */
.gear.reverse {
  color: var(--op-red-hi);
  --aug-border-bg: var(--op-red-hi);
}

.meta {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: var(--op-space-2);
  /* THE LINE KEEPS THE AIRBORNE CHIP'S HEIGHT WHETHER OR NOT IT IS UP. The block is
     anchored by its bottom edge, so this line growing by the chip (its 10px type plus
     4px above and below) pushed the whole dial up 7px every time the car left the
     ground, and dropped it back on landing. */
  min-height: calc(var(--op-fs-label) + 8px);
  /* NO GROUND. A plate went under this line and came straight back off on the
     owner's word, with the rest of the HUD's; the padding went with it, because
     it was only ever there to keep the plate off the glyphs. */
}

.integrity-row {
  display: flex;
  align-items: baseline;
  gap: var(--op-space-1);
}

.integrity-row .label {
  font: 400 var(--op-fs-micro) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  text-transform: uppercase;
  color: var(--op-red-idle);
  white-space: nowrap;
}

.integrity-row b {
  font: 700 var(--op-fs-meta) / 1 var(--op-font-mono);
  color: var(--op-red);
  font-variant-numeric: tabular-nums;
}

.integrity-row.warn b {
  color: var(--op-red-hi);
}

.integrity-row.bad b {
  color: var(--op-alarm);
}

/* =============================================================================
   THE TANK -- the integrity line's twin, with a hairline gauge between the word
   and the number: a frame that is an outline and a fill that is the quantity,
   the same division the dial's rings make. Only the fill's width moves.
   ========================================================================== */
.fuel-row {
  display: flex;
  align-items: center;
  gap: var(--op-space-1);
}

.fuel-row .label {
  font: 400 var(--op-fs-micro) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  text-transform: uppercase;
  color: var(--op-red-idle);
  white-space: nowrap;
}

.fuel-track {
  position: relative;
  width: 36px;
  height: 4px;
  border: 1px solid var(--op-red-idle);
}

.fuel-fill {
  position: absolute;
  inset: 0 auto 0 0;
  background: var(--op-red);
  transition: width var(--op-dur-fast) linear;
}

.fuel-row b {
  font: 700 var(--op-fs-meta) / 1 var(--op-font-mono);
  color: var(--op-red);
  font-variant-numeric: tabular-nums;
}

.fuel-row.warn .fuel-fill {
  background: var(--op-red-hi);
}

.fuel-row.warn b {
  color: var(--op-red-hi);
}

.fuel-row.bad .fuel-fill {
  background: var(--op-alarm);
}

.fuel-row.bad b {
  color: var(--op-alarm);
}

/* =============================================================================
   THE AIRBORNE CHIP -- the same object HudStatus.vue draws, and it is local for
   the same reason: `OpChip` is `.op-tag` plus `data-augmented-ui` plus a panel
   fill, and it is shared with the admin staff tags. Two small copies live in this
   folder while the pass is being settled and both go when the frame is promoted
   back into `design/`.
   ========================================================================== */
.chip {
  display: inline-flex;
  align-items: center;
  gap: var(--op-space-2);
  padding: 4px var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-sm));
  font: 700 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  white-space: nowrap;
  color: var(--op-red);
  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2px;
}

.chip-icon {
  flex: none;
  font: 900 var(--op-fs-meta) / 1 var(--op-font-mono);
}
</style>
