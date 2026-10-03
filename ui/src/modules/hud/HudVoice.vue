<script setup lang="ts">
import { shallowRef } from 'vue'
import { num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE VOICE ROW -- one line at the foot of the vitals column, drawn like the gauges above it.
 *
 * IT WAS A BLOCK OF ITS OWN IN THE BOTTOM-RIGHT CORNER, and that corner is the minimap's
 * now. The owner moved the game's map down there and made it round ("would like it on
 * bottom of screen not top, move the voice ui or whatever is in the way and redesign it
 * smaller to fit in the health ui"), so the microphone joined the gauges: the same
 * glyph column, the same chamfered track, the same readout column, one row tall. The
 * block was up to 220px of mic, caption, meter, mode, pips, two keycaps and a counter;
 * the row is 16px.
 *
 * WHAT THE ROW KEEPS, and why each survived the cut:
 *   * the MICROPHONE GLYPH -- the state, by colour and by a slash for muted and offline,
 *     so it never depends on colour alone;
 *   * the INPUT LEVEL -- the track, as slats lit from the left, because "am I being
 *     picked up" is the question a voice indicator exists to answer;
 *   * the REACH -- the mode and its distance in the readout column ("NORMAL 15 M"),
 *     because what you say depends on who can hear it;
 *   * the RX COUNT -- how many players are audible, only while somebody is.
 * WHAT IT DROPS: the caption (the glyph's state says it), the mode pips (the mode's name
 * says which one it is), and the two keycaps (the bindings screen owns key names; a HUD
 * that spells them out at all times is a tutorial that never ends).
 *
 * Lua decides the state and every word, exactly as before: this lights what it is told
 * and never infers. `talking` is not "the meter is above a threshold", it is what the
 * voice stack said.
 *
 * THE STATE LADDER IS THE GAUGES' OWN. Resting is the quiet red, `detected` the deep
 * rung, `talking` the full red with the unlit slats dropped away so the lit ones stand
 * alone, and `muted` -- a failure to transmit -- the white-hot alarm, the same rule the
 * `bad` gauge follows.
 */
const { t } = useLocale()

withDefaults(defineProps<{ segments?: number }>(), { segments: 8 })

type State = 'idle' | 'detected' | 'talking' | 'muted' | 'offline'

const STATES: readonly string[] = ['idle', 'detected', 'talking', 'muted', 'offline']

interface Voice {
  active: boolean
  state: State
  mode: string
  distance: string
  /** 0..100, the input level. */
  level: number
  /** How many players are audible right now. */
  heard: number
}

const EMPTY: Voice = {
  active: false,
  state: 'offline',
  mode: '',
  distance: '',
  level: 0,
  heard: 0
}

const voice = shallowRef<Voice>(EMPTY)

useBridge('opx:hud:voice', (payload: Payload) => {
  if (payload.active !== true) {
    // Not emptied: the row leaves on `active`, and a cleared payload would make it go
    // with its reach already blank.
    voice.value = { ...voice.value, active: false }
    return
  }

  const state = text(payload.state, 'offline')
  voice.value = {
    active: true,
    state: (STATES.indexOf(state) === -1 ? 'offline' : state) as State,
    mode: t(text(payload.mode)),
    distance: text(payload.distance),
    level: Math.max(0, Math.min(100, num(payload.level))),
    heard: Math.max(0, Math.round(num(payload.heard)))
  }
})

/** 0..1, for the meter's `clip-path`: the level is the fastest-moving number in the row,
    so it moves the way that costs neither a layout nor a paint. A clip, not a scale --
    a scale would take the slat mask with it and draw a second set of bars over the
    first (the owner's "bars over the bars"). */
function share(value: number): number {
  return Math.max(0, Math.min(100, value)) / 100
}
</script>

<template>
  <div
    class="voice"
    :class="[voice.state, { live: voice.active }]"
    :style="{ '--segs': segments }"
    role="group"
    :aria-hidden="!voice.active"
    aria-label="voice"
  >
    <span class="mic" aria-hidden="true">
      <svg
        viewBox="0 0 16 16"
        fill="none"
        stroke="currentColor"
        stroke-width="1.6"
        stroke-linecap="round"
        stroke-linejoin="round"
      >
        <path d="M8 10.2a2.5 2.5 0 0 0 2.5-2.5V4.1a2.5 2.5 0 1 0-5 0v3.6A2.5 2.5 0 0 0 8 10.2Z" />
        <path d="M3.9 7.2v.5a4.1 4.1 0 0 0 8.2 0v-.5M8 11.8v2.4M5.9 14.2h4.2" />
      </svg>
      <!-- The slash draws itself on with a scaleX on a child, never on the glyph. -->
      <i class="slash" />
    </span>

    <!-- THE METER: the gauges' chamfered track, holding the configured number of slats
         lit from the left instead of a bar. -->
    <span
      class="track"
      data-augmented-ui="tr-clip border"
      role="meter"
      aria-label="voice level"
      :aria-valuenow="Math.round(voice.level)"
      :aria-valuemin="0"
      :aria-valuemax="100"
    >
      <span class="slats">
        <span class="fill" :style="{ clipPath: `inset(0 ${(1 - share(voice.level)) * 100}% 0 0)` }" />
      </span>
    </span>

    <span v-if="voice.mode || voice.distance" class="reach">
      <span v-if="voice.mode" class="mode op-truncate">{{ voice.mode }}</span>
      <span v-if="voice.distance" class="distance">{{ voice.distance }}</span>
    </span>

    <!-- The one live counter in the row, so the one thing allowed to bloom. -->
    <span v-if="voice.heard > 0" class="rx" data-augmented-ui="tr-clip border">
      <span class="rx-icon">RX</span>
      <span>{{ voice.heard }}</span>
    </span>
  </div>
</template>

<style scoped>
/* =============================================================================
   THE ROW -- a gauge row's geometry: the 14px glyph column, a flexible track,
   then the readout. It lives inside `.vitals`, so it rides that column's plane,
   tilt and anchor; it positions nothing itself.
   ========================================================================== */
.voice {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  height: 16px;
  opacity: 0;
  /* In from the column's own edge: the gauges stutter in from the left. */
  transform: translate3d(-8px, 0, 0);
  transition:
    opacity var(--op-enter-ms) var(--op-stutter),
    transform var(--op-enter-ms) var(--op-stutter);
  /* The state ladder, resolved once and read by the glyph, the track and the reach. */
  --voice-tone: var(--op-red-idle);
  --voice-unlit: rgba(var(--op-red-idle-rgb), 0.38);
  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: var(--voice-tone);
  color: var(--voice-tone);
}

.voice.live {
  opacity: 1;
  transform: translate3d(0, 0, 0);
}

.idle {
  --voice-tone: var(--op-red-idle);
}

/* Something is arriving; the player is not through yet. */
.detected {
  --voice-tone: var(--op-red-deep);
}

/* TALKING HAS TO BE UNMISTAKABLE: the unlit slats drop away so the lit ones stand
   alone instead of being a brighter red among red, and the frame takes the 2px rule
   a toned gauge takes. Contrast, not a filter -- this repaints while somebody speaks.
   THE BLOOM IS NOT THE ANSWER: `.op-lift` is a `drop-shadow` filter, and
   `design-system/shapes.css` forbids a filter on anything whose value moves every
   frame, which the meter does for as long as somebody talks. */
.talking {
  --voice-tone: var(--op-red);
  --voice-unlit: rgba(var(--op-red-idle-rgb), 0.12);
  --aug-border-all: 2px;
}

/* THE ALARM, AND NOT A RED: muted is a failure to transmit. */
.muted {
  --voice-tone: var(--op-alarm);
  --aug-border-all: 2px;
}

/* No stack, nothing to say: the only place in this folder where the grey ink is right. */
.offline {
  --voice-tone: var(--op-text-faint);
}

/* =============================================================================
   THE GLYPH -- the gauges' 14px column, so the microphone sits under the heart.
   ========================================================================== */
.mic {
  position: relative;
  flex: none;
  width: 14px;
  height: 14px;
  color: var(--voice-tone);
  transition: color var(--op-dur-fast) linear;
}

.mic svg {
  display: block;
  width: 100%;
  height: 100%;
  /* An SVG stroke takes no text-shadow, so the black is one drop-shadow on a 14px
     glyph -- static, like the gauges' glyphs. */
  filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.95));
}

.talking .mic {
  /* A bloom BEHIND the glyph, not a second filter on it: swapping a filter on a state
     change re-rasterises the strokes. */
  border-radius: 50%;
  box-shadow: 0 0 12px -2px var(--op-red-glow);
}

.slash {
  position: absolute;
  left: 50%;
  top: 50%;
  width: 17px;
  height: 2px;
  background: var(--voice-tone);
  transform: translate(-50%, -50%) rotate(-45deg) scaleX(0);
  transition: transform var(--op-dur-fast) linear;
}

.muted .slash,
.offline .slash {
  transform: translate(-50%, -50%) rotate(-45deg) scaleX(1);
}

/* =============================================================================
   THE TRACK -- the gauges' frame (1px, chamfered top-right, 3px clearance), with
   the level as slats lit from the left. The unlit slats are one static gradient;
   the lit ones are the same gradient on a clipped child, so they land exactly in
   the unlit ones whatever the level.

   NO INTERLACE. It went with the old voice block's frame: the interlace exists to
   stop an unfilled FRAME reading as a web page floating in the air, and a striped
   rectangle with no frame IS that rectangle. This track is never unfilled -- its
   slats are its content -- so there is nothing for it to do here either.
   ========================================================================== */
.track {
  position: relative;
  box-sizing: border-box;
  /* A FIXED METER, NOT A FLEXIBLE ONE. It starts where the gauges' tracks start and
     is its own, shorter instrument: an input level, not a pool. Fixed, because a
     flexible one changed width whenever the rx counter came and went, and gave way
     to the words -- a long reach squeezed it to its chamfer. 52px holds the eight
     slats and leaves "NORMAL 15 M" whole beside a live rx counter in the 210px
     column; longer words truncate instead (below). */
  flex: none;
  width: 52px;
  height: 16px;
  padding: 3px;
}

.slats {
  position: relative;
  display: block;
  width: 100%;
  height: 100%;
  /* The bar's own cut, 5px where the frame's is 8 (3px in along the diagonal). */
  clip-path: polygon(0 0, calc(100% - 5px) 0, 100% 5px, 100% 100%, 0 100%);
  background-image: repeating-linear-gradient(
    to right,
    var(--voice-unlit) 0 calc(100% / var(--segs, 8) - 2px),
    transparent calc(100% / var(--segs, 8) - 2px) calc(100% / var(--segs, 8))
  );
}

.fill {
  position: absolute;
  inset: 0;
  background-image: repeating-linear-gradient(
    to right,
    var(--voice-tone) 0 calc(100% / var(--segs, 8) - 2px),
    transparent calc(100% / var(--segs, 8) - 2px) calc(100% / var(--segs, 8))
  );
  /* Lit from the left by revealing an unscaled element: `inset(0 100% 0 0)` is the
     rest state, nothing lit. */
  clip-path: inset(0 100% 0 0);
  transition: clip-path var(--op-dur-fast) linear;
}

/* =============================================================================
   THE READOUT -- the reach, in the gauges' readout type. Never wrapped: "NORMAL"
   broken over two lines reads as two modes.
   ========================================================================== */
.reach {
  /* The one part of the row that gives: the column is 210px and the row has to end
     inside it, rx counter and all. */
  flex: 0 1 auto;
  min-width: 0;
  display: flex;
  align-items: baseline;
  gap: 5px;
  font: 700 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  font-variant-numeric: tabular-nums;
  text-transform: uppercase;
  white-space: nowrap;
}

/* THE WORD TRUNCATES, THE DISTANCE NEVER DOES. "15 M" is the fact; the mode's name
   is how the player asked for it, and an open-voice label the catalogue has no word
   for can be any length. The cut is the design system's one `.op-truncate` (on the
   element); this only lets the word be the thing that shrinks. */
.mode {
  flex: 0 1 auto;
  color: var(--voice-tone);
}

.distance {
  flex: none;
  color: var(--op-red-idle);
}

/* =============================================================================
   THE RX COUNTER -- how many players are audible, lit and blooming, and only there
   while somebody is talking. No pulse: an animation that never ends keeps a
   compositor animation alive on the surface that never stops drawing.
   ========================================================================== */
.rx {
  flex: none;
  display: inline-flex;
  align-items: center;
  gap: 3px;
  height: 16px;
  padding: 0 calc(4px + var(--op-cut-sm)) 0 4px;
  box-sizing: border-box;
  font: 700 var(--op-fs-micro) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  font-variant-numeric: tabular-nums;
  color: var(--op-red);
  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 1px;
  /* THE BLOOM IS A FILTER, on the surface that forbids them, and this is the exception
     the rule allows: the counter appears when somebody starts talking and changes when
     the set of speakers does -- never per frame -- and a clip shears an outset shadow,
     so this is the only bloom that follows the cut. */
  filter: drop-shadow(0 0 4px var(--op-red-glow));
}

.rx-icon {
  font-weight: 900;
  color: var(--op-red-hi);
}
</style>
