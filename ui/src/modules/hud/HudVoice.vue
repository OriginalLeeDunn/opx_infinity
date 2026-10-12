<script setup lang="ts">
import { shallowRef } from 'vue'
import { num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'
import { corners } from '@/stores/corners'

/**
 * THE VOICE BLOCK -- bottom-right corner, on the same insets as every anchored cluster.
 *
 * IT WAS MID-RIGHT, AND THE MIDDLE OF AN EDGE IS THE WORST PLACE A BLOCK OF THIS SHAPE
 * CAN SIT. Vertically centred, a 52-to-220px column of mic, meter, mode, pips, keycaps
 * and counter lands exactly at eye level -- over the road, over the crosshair's
 * neighbours, over whatever the player is actually looking at -- and it is the one
 * block on this HUD that is TALLER THAN IT IS WIDE, so at eye level it is a stripe
 * across the middle of the view rather than a read-out in a corner. Every other cluster
 * already reads its own corner. This one now does too.
 *
 * The corner is `bottom-right`, and for two reasons it is that one and not `bottom-left`:
 * the block is right-anchored (its chamfers, its lit arete and the sign of its tilt all
 * follow the right edge, and `railOf` has answered `end` for it since the port), and
 * voting in `HudRoot.vue` puts the vitals column and the chip strip in the bottom-left
 * and the vehicle chip at the bottom centre -- so the bottom-right was the free corner
 * on an already-full edge.
 *
 * Lua decides the state and every word. This lights what it is told and never infers:
 * `talking` is not "the meter is above a threshold", it is what the voice stack said.
 *
 * -- DESIGN PASS 02 -----------------------------------------------------------
 *
 * IT DRAWS ITS OWN EVERYTHING NOW. It was an `OpPanel` holding an `OpGauge`, two
 * `OpKeyCap`s and an `OpChip` -- four shared components, every one of them either
 * augmented, filled, or both. The frame, the meter, the keycaps and the counter are all
 * local, exactly as MenuView.vue carries a local frame and row, and for the same reason:
 * the four shared ones are used by surfaces nobody has looked at yet.
 *
 * THIS BLOCK PINS ITSELF, so unlike the other four it is its own positioned wrapper: it
 * carries the perspective, the paint containment and the tilt sign itself. It is anchored
 * to the RIGHT edge, so the sign is negative and the plane pivots on the right -- and it
 * stays right-anchored in its new corner, which is why the tilt and the transform origin
 * did not change with the position and only the vertical anchor did.
 *
 * THE STATE LADDER IS THE MENU'S THREE STEPS PLUS THE ALARM. The HUD takes no pointer, so
 * `--red-deep` -- the menu's hover rung -- is free, and `detected` is exactly what it is
 * for: something is arriving but the player is not through yet. `muted` is the one state
 * that is a FAILURE to transmit, so it takes the white-hot alarm and not a red, which is
 * the same rule the gauges follow and the reason the mic has a slash as well.
 */
const { t } = useLocale()

withDefaults(defineProps<{ segments?: number }>(), { segments: 8 })

type State = 'idle' | 'detected' | 'talking' | 'muted' | 'offline'

const STATES: readonly string[] = ['idle', 'detected', 'talking', 'muted', 'offline']

interface Voice {
  active: boolean
  state: State
  caption: string
  mode: string
  distance: string
  /** 0..100, the input level. */
  level: number
  /** How many reach modes there are, and which one is current. */
  count: number
  index: number
  key: string
  activation: string
  /** How many players are audible right now. */
  heard: number
}

const EMPTY: Voice = {
  active: false,
  state: 'offline',
  caption: '',
  mode: '',
  distance: '',
  level: 0,
  count: 0,
  index: 0,
  key: '',
  activation: '',
  heard: 0
}

const voice = shallowRef<Voice>(EMPTY)

useBridge('opx:hud:voice', (payload: Payload) => {
  if (payload.active !== true) {
    // Not emptied: the block leaves on `active`, and a cleared payload would make it go
    // with its caption already gone.
    voice.value = { ...voice.value, active: false }
    return
  }

  const state = text(payload.state, 'offline')
  const count = Math.max(0, Math.min(8, Math.round(num(payload.count))))

  voice.value = {
    active: true,
    state: (STATES.indexOf(state) === -1 ? 'offline' : state) as State,
    caption: t(text(payload.caption)),
    mode: t(text(payload.mode)),
    distance: text(payload.distance),
    level: Math.max(0, Math.min(100, num(payload.level))),
    count,
    index: Math.max(0, Math.min(count, Math.round(num(payload.index)))),
    key: text(payload.key),
    activation: text(payload.activation),
    heard: Math.max(0, Math.round(num(payload.heard)))
  }
})

/** 0..1, for the meter's `translateY`. An input level is the fastest-moving number on
    this block, so it moves the one way that costs neither a layout nor a paint: a
    transform on a solid fill, under a mask that does not move (#114). */
function share(value: number): number {
  return Math.max(0, Math.min(100, value)) / 100
}
</script>

<template>
  <div
    class="voice"
    :class="[voice.state, { live: voice.active }]"
    :style="{ '--voice-lift': corners.bottomRight + 'px' }"
  >
    <section class="panel">
      <div class="inner">
        <div class="head">
          <span class="mic">
            <svg
              viewBox="0 0 16 16"
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path
                d="M8 10.2a2.5 2.5 0 0 0 2.5-2.5V4.1a2.5 2.5 0 1 0-5 0v3.6A2.5 2.5 0 0 0 8 10.2Z"
              />
              <path d="M3.9 7.2v.5a4.1 4.1 0 0 0 8.2 0v-.5M8 11.8v2.4M5.9 14.2h4.2" />
            </svg>
            <!-- The slash draws itself on with a scaleX on a child, never on the frame. -->
            <i class="slash" />
          </span>
          <span v-if="voice.caption" class="caption op-truncate">{{ voice.caption }}</span>
        </div>

        <!-- THE METER. The same object HudVitals.vue draws: a chamfered 1px track with
             the configured graduations on it and one filled bar inside, held 3px off the
             frame so its corner lands on the chamfer. No readout -- a mic level is a
             shape, not a number. -->
        <span
          class="track"
          :style="{ '--segs': segments }"
          role="meter"
          aria-label="voice"
          :aria-valuenow="Math.round(voice.level)"
          :aria-valuemin="0"
          :aria-valuemax="100"
        >
          <!-- THE MASK STANDS STILL AND THE FILL SLIDES UNDER IT.
               The slats are a mask cut to the same 4px-on, 2px-off rhythm as the
               unlit column behind, and it must never move with the level: a
               `scaleY()` on the masked element scaled the mask too, the 6px pitch
               became 3px at half level, and the eye read a second set of bars over
               the first ("it draws bars over the bars"). The fix after that was a
               `clip-path` on the masked fill -- right to look at, but a clip-path
               change is a repaint of a masked element at the fastest-moving number
               on the HUD (#114).
               So the mask is on `.meter`, which never changes, and the fill
               inside it is one solid colour moved down by `translateY`: the part
               of it still inside the meter is exactly what `inset(top 0 0 0)`
               revealed, and a transform is the compositor's alone. -->
          <span class="meter">
            <span class="fill" :style="{ transform: `translateY(${(1 - share(voice.level)) * 100}%)` }" />
          </span>
        </span>

        <div v-if="voice.mode || voice.distance" class="reach">
          <span v-if="voice.mode" class="mode">{{ voice.mode }}</span>
          <span v-if="voice.distance" class="distance">{{ voice.distance }}</span>
        </div>

        <!-- Which reach mode of the cycle is active. Not a meter: a meter is a quantity
             and this is a selection, so each one is an outline that goes bright, which is
             the reference's whole answer for a chosen thing. -->
        <div v-if="voice.count > 0" class="pips">
          <i v-for="n in voice.count" :key="n" class="pip" :class="{ on: n <= voice.index }" />
        </div>

        <div v-if="voice.key || voice.activation" class="keys">
          <kbd v-if="voice.key" class="cap" data-augmented-ui="tr-clip border">{{ voice.key }}</kbd>
          <!-- The activation key rests at the quiet rung: it is how you talk, not what
               you press to act. -->
          <kbd
            v-if="voice.activation"
            class="cap quiet"
            data-augmented-ui="tr-clip border"
          >{{ voice.activation }}</kbd>
        </div>

        <!-- The one live counter here, so the one thing allowed to bloom. -->
        <span v-if="voice.heard > 0" class="rx" data-augmented-ui="tr-clip border">
          <span class="rx-icon">RX</span>
          <span>{{ voice.heard }}</span>
        </span>
      </div>
    </section>
  </div>
</template>

<style scoped>
/* =============================================================================
   THE WRAPPER -- this block pins itself, so this is the positioned element and it
   carries what `.at` carries for the other four: the perspective, the paint
   containment and the bleed the containment needs so a shadow is not clipped off.
   ========================================================================== */
.voice {
  position: fixed;
  box-sizing: border-box;
  right: calc(var(--op-inset-x) - var(--hud-bleed));
  /* THE BOTTOM-RIGHT CORNER, on `.at`'s own offsets: the same inset token and the same
     bleed payback every anchored cluster uses, so this block lines up with the vitals
     column's baseline and the vehicle chip's, and a change to --op-inset-y moves all
     three together. `bottom` and not `top`, so the block GROWS UPWARD as its lines
     arrive -- the meter, the reach mode, the pips and the keycaps are all conditional,
     and a top-anchored block would slide its own mic down the screen every time a line
     appeared above it. */
  bottom: calc(var(--op-inset-y) - var(--hud-bleed));
  /* IT IS SIZED BY ITS WIDEST LINE, and it was not.

     `opx77_hud/web/hud.css` pinned `.voice` at 52px: a narrow column hugging the
     right edge, its lines centred and ALLOWED TO RUN PAST IT rather than a box
     sized to hold them. That is how the original read, and the note kept here
     said so -- but this block also carries `contain: paint`, and paint
     containment clips to the padding box. A line running past a 52px column was
     not running past it. It was being cut off 10px out, and everything wider
     than the microphone lost its ends: the caption (ellipsised to about 22px of
     room), the reach mode and its distance, both keycaps, the RX counter.

     So there is no width now. A fixed-position box shrink-to-fits, which sizes
     this one to its widest line and nothing more, and the column still READS as
     narrow because `.inner` centres everything in it -- the part of 52px that
     was ever visible. The floor keeps the mic and the meter where they sat when
     nothing else is drawn; the ceiling stops a long translation turning an
     instrument into a banner, and `.caption` keeps its ellipsis for that case. */
  min-width: calc(52px + var(--hud-bleed) * 2);
  max-width: calc(220px + var(--hud-bleed) * 2);
  padding: var(--hud-bleed);
  opacity: 0;
  /* In from the corner it lives in: the horizontal 8px is the original, the vertical
     one replaces the -50% that used to centre it. The lift over an open key strip
     rides on the same transform (see `transition` below). */
  transform: translate(8px, calc(8px - var(--voice-lift, 0px)));
  perspective: var(--op-persp);
  contain: layout paint style;
  /* An entrance: three steps, not a fade. */
  /* The block steps up over an open key strip and back down when it closes
     (`stores/corners.ts`), and a jump would read as a glitch. That step was a
     transition on `bottom` -- a layout per frame -- and is now part of the
     `transform` below, on the same timing (#114). */
  transition:
    opacity var(--op-enter-ms) var(--op-stutter),
    transform var(--op-enter-ms) var(--op-stutter);
  /* The state ladder, resolved once and read by the mic, the caption, the meter
     and the slash. NOT by the frame: `--voice-frame` sat here for four states
     and nothing ever read it, so the caps and the rx counter never followed the
     voice state and do not start now -- reviving a dead variable during a
     port is a look change nobody asked for. */
  --voice-tone: var(--op-red-idle);
  /* The dead slats behind the fill. Its own variable so `.talking` can drop it
     away without touching the lit tone -- see that state for why. */
  --voice-unlit: var(--op-red-idle);
}

.voice.live {
  opacity: 1;
  transform: translate(0, calc(var(--voice-lift, 0px) * -1));
}

/* At rest. */
.idle {
  --voice-tone: var(--op-red-idle);
}

/* The middle rung -- the menu's hover step, unspent on a HUD that takes no
   pointer. Something is arriving; the player is not through yet. */
.detected {
  --voice-tone: var(--op-red-deep);
}

/* TALKING HAS TO BE UNMISTAKABLE, and a shade of red against a shade of red was
   not. This state used to change one thing -- `--voice-tone` from `--op-red-idle`
   to `--op-red` -- and both are the same hue at 62% and 100%, sitting in a column
   of unlit slats painted in the first of them. The owner's words were that you
   cannot really tell you are talking, and they were right: the lit bars and the
   dead ones were nearly the same colour.

   THE BLOOM IS NOT THE ANSWER, whatever the old comment here claimed. `.op-lift`
   is a `drop-shadow` filter and `design-system/shapes.css` says outright that
   nothing repainting every frame may take one. A voice meter repaints while
   somebody is speaking, which is precisely when this state is on.

   So the answer is CONTRAST, which costs nothing: the unlit column drops away
   while talking, so the lit slats stand alone instead of being a slightly
   brighter red among red. Same hue, same shapes, no filter, no second colour --
   the rung the contract already gives for "this one, not those". */
.talking {
  --voice-tone: var(--op-red);
  --voice-unlit: rgba(var(--op-red-idle-rgb), 0.16);
}

/* THE ALARM, AND NOT A RED. Muted is a failure to transmit -- the player is
   talking and nobody can hear it -- so it takes the white-hot step, for the same
   reason a `bad` gauge does: red is this surface's voice and cannot also be its
   alarm. The slash carries it as well, so the state does not depend on colour
   alone. */
.muted {
  --voice-tone: var(--op-alarm);
}

/* Not a state of the voice so much as the absence of one: no stack, nothing to
   say, and the only place in this folder where the grey ink is right. */
.offline {
  --voice-tone: var(--op-text-faint);
}

/* =============================================================================
   THE FRAME -- no fill, two opposite chamfers, and the plane that tilts. Mirrored
   for the right edge from the start: this block has only ever lived over there,
   so the leading edge is the right one and the arete follows it.
   ========================================================================== */
.panel {
  position: relative;
/* NO ENCLOSURE. It had a chamfered frame with an inset outline; the old
   `opx77_hud` drew none, and neither does this now. A HUD block is an
   INSTRUMENT sitting on the gameplay plane, not a panel: the three clusters
   that never had a box read correctly without one, and boxing these two made
   them the odd pair out. The tilt, the type, the reds and the shadows stay --
   only the container loses its edges. */
  /* Right-anchored, so -7deg, pivoting on the right. */
  transform-origin: right center;
  transform: rotateY(calc(var(--op-tilt) * -1));

  /* NO GROUND. A plate went here and came straight back off on the owner's word,
     with the rest of the HUD's. The reason it is worth recording rather than
     just deleting: if one is ever put back it belongs on THIS element and not on
     `.inner`, which is the one holding the lines and looks like the obvious
     place. `.track::after` draws the unlit slats of the meter at `z-index: -1`,
     and a negative child paints below every background in its stacking context
     except the one belonging to the element that establishes it -- which is this
     one, because it carries the `rotateY`. A plate one level down eats the
     slats. */
}

.inner {
  position: relative;
  display: flex;
  flex-direction: column;
  /* Centred and unpadded, as the old stack was: with no frame there is no inner
     edge to hang off, so every line is centred on one axis and the block is as
     wide as the widest of them. Each line is still `nowrap` -- none of them is
     a sentence, and a mode name broken over two lines reads as two modes. */
  align-items: center;
  gap: 6px;
}

/* The interlace went with the frame. It existed to stop an unfilled FRAME
   reading as a web page floating in the air; with no frame, a striped
   rectangle IS that floating rectangle. */

.head {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  width: 100%;
}

.mic {
  position: relative;
  flex: none;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 22px;
  height: 22px;
  color: var(--voice-tone);
  transition:
    color var(--op-dur-fast) linear,
    box-shadow var(--op-dur-fast) linear;
}

.mic svg {
  display: block;
  width: 18px;
  height: 18px;
  /* An SVG stroke takes no text-shadow, so the black is one drop-shadow on an
     18px glyph -- static, and the only filter on this block. The `talking` bloom
     that used to be a SECOND drop-shadow here is a `box-shadow` on `.mic` below:
     swapping a filter on a state change re-rasterises the glyph, and a bloom is a
     shape behind the icon rather than a property of its strokes. */
  filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.95));
}

.talking .mic {
  box-shadow: 0 0 16px -4px var(--op-red-glow);
}

.slash {
  position: absolute;
  left: 50%;
  top: 50%;
  width: 22px;
  height: 2px;
  background: var(--voice-tone);
  transform: translate(-50%, -50%) rotate(-45deg) scaleX(0);
  transition: transform var(--op-dur-fast) linear;
}

.muted .slash,
.offline .slash {
  transform: translate(-50%, -50%) rotate(-45deg) scaleX(1);
}

.caption {
  flex: 1;
  text-align: right;
  font: 700 var(--op-fs-micro) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  text-transform: uppercase;
  color: var(--voice-tone);
}

.talking .caption {
  text-shadow:
    0 1px 2px rgba(0, 0, 0, 0.95),
    0 0 9px rgba(0, 0, 0, 0.8),
    0 0 10px var(--op-red-glow);
}

/* =============================================================================
   THE METER -- HudVitals.vue's gauge without the readout. Two small copies of
   twenty lines, and they are deliberate for the life of this pass: the shared one
   is `OpGauge`, which the panel module also draws, and both copies go when the
   frame is promoted back into `design/`.
   ========================================================================== */
/* STACKED, AND UPWARDS. `opx77_hud` drew the input level as a column of sheared
   slats lit from the bottom, and that is the shape the owner wants back -- a
   horizontal bar reads as a progress bar, which a mic level is not.

   It is still ONE node, not twenty. The old resource toggled a class on up to
   twenty `.block` children every frame the level moved; the slats here are a
   STATIC gradient and the level is one `translateY` on one composited child, so the
   look comes back without the twenty per-frame class writes coming back with it. */
.track {
  position: relative;
  box-sizing: border-box;
  width: 22px;
  height: 46px;
  padding: 2px;
}

/* Lua's segment count as hairline graduations on the track: a line, not a fill,
   and one static gradient however fast the level moves. */
/* The unlit column: the same slats at rest, under the fill and behind it. One
   static gradient, painted once, whatever the level does. `--segs` no longer
   divides it -- a slat is a fixed 4px with a 2px gap, as the original drew it,
   so the column reads the same height whether Lua says eight or twenty. */
.track::after {
  content: "";
  position: absolute;
  inset: 2px;
  z-index: -1;
  pointer-events: none;
  background-image: repeating-linear-gradient(
    to top,
    var(--voice-unlit) 0 4px,
    transparent 4px 6px
  );
}

/* The window the level shows through. Static: it carries the slat divisions,
   cut OUT of whatever slides under it, so the gaps show the night behind instead
   of a darker red -- and since nothing about it ever changes, the mask is drawn
   once. `overflow: hidden` is the cut the old `inset()` made. */
.meter {
  display: block;
  width: 100%;
  height: 100%;
  overflow: hidden;
  -webkit-mask-image: repeating-linear-gradient(to top, #000 0 4px, transparent 4px 6px);
  mask-image: repeating-linear-gradient(to top, #000 0 4px, transparent 4px 6px);
}

/* The one filled shape on this block, and it is data: a solid colour, lit from
   the bottom by sliding a full-height element up into the meter rather than by
   squashing it. `translateY(100%)` is entirely below the window, which is the
   rest state. Only the transform moves per frame. */
.fill {
  display: block;
  width: 100%;
  height: 100%;
  background: var(--voice-tone);
  transform: translateY(100%);
  transition:
    transform var(--op-dur-fast) linear,
    background var(--op-dur-fast) linear;
}

.reach {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: var(--op-space-2);
  width: 100%;
}

.mode {
  font: 700 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: var(--op-red);
  white-space: nowrap;
}

.distance {
  font: 700 var(--op-fs-meta) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: var(--op-red-idle);
  font-variant-numeric: tabular-nums;
  /* `.caption` and `.mode` already refuse to wrap; this one is a formatted
     sentence rather than a bare number ("15 m", and whatever a translation makes
     of it), so it gets the same refusal rather than being trusted to be short. */
  white-space: nowrap;
}

/* =============================================================================
   THE PIPS -- which reach mode of the cycle is active. Outlines, and the chosen
   ones go bright: the reference's rule for a selected thing, at 10px.

   NO CHAMFER AND NO CLIP HERE. A 6px cut on a 10px box is not a house shape, it
   is a triangle, and a `clip-path` on a repeated element is the one thing the
   performance notes name twice. A plain 1px border is the honest answer at this
   size.
   ========================================================================== */
.pips {
  display: flex;
  gap: 3px;
}

.pip {
  width: 10px;
  height: 8px;
  border: 1px solid var(--op-red-idle);
  box-shadow: var(--hud-shadow);
  transition:
    border-color var(--op-dur-fast) linear,
    box-shadow var(--op-dur-fast) linear;
}

.pip.on {
  border-color: var(--op-red);
  box-shadow:
    var(--hud-shadow),
    0 0 10px -2px var(--op-red-glow);
}

/* =============================================================================
   THE KEYCAPS -- local, because `OpKeyCap` is `.op-tag` plus `data-augmented-ui`
   plus an `--op77-accent-soft` fill and an accent under-rule, and all three are
   off-spec here. The weighted base the shared one is built around does not
   survive: a bottom rule 2px thick IS a fill, however thin. What is left is the
   house frame and the type, which is what a key looks like on this surface now.
   ========================================================================== */
.keys {
  display: flex;
  gap: var(--op-space-1);
}

.cap {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 24px;
  height: 22px;
  padding: 0 7px;
  padding-right: calc(7px + var(--op-cut-sm));
  font: 700 var(--op-fs-meta) / 1 var(--op-font-mono);
  letter-spacing: 0.04em;
  color: var(--op-red);
  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2px;
}

.cap.quiet {
  color: var(--op-red-idle);
  --aug-border-bg: var(--op-red-idle);
  --aug-border-all: 1px;
}

/* =============================================================================
   THE RX COUNTER -- how many players are audible. Lit and blooming, which is the
   whole of its state.

   THE PULSE IS GONE. It was a 1.1s infinite opacity animation, and an animation
   that never ends keeps a compositor animation alive for the whole session on the
   one surface that never stops drawing -- tokens.css says "no idle animation" and
   means it. A counter that is only there when somebody is talking does not also
   have to blink to say so.
   ========================================================================== */
.rx {
  display: inline-flex;
  align-items: center;
  gap: var(--op-space-2);
  padding: 4px var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-sm));
  font: 700 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  font-variant-numeric: tabular-nums;
  color: var(--op-red);
  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2px;
  /* THE BLOOM IS A FILTER, on the surface that forbids them -- and this is the
     exception the rule allows for. `shapes.css` bans a filter on anything whose
     VALUE changes every frame, because that is what costs a backing store per
     repaint; the rx counter appears when somebody starts talking and changes
     when the set of speakers does. A clip shears an outset shadow, so this is
     the only bloom that follows the cut. */
  filter: drop-shadow(0 0 5px var(--op-red-glow));
}

.rx-icon {
  flex: none;
  font-weight: 900;
  color: var(--op-red-hi);
}
</style>
