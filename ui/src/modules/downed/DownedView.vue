<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { num, table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useCountdown } from '@/composables/useCountdown'
import { GLYPHS } from '@/modules/target/glyphs'

/**
 * THE DOWN SCREEN -- what a player sees while they are bleeding out, and the two
 * ways off it.
 *
 * `modules/downed` has owned this since it was written and has never had a
 * surface: the Lua half publishes `config`, `show`, `hide`, `notice` and `focus`
 * on one seam and takes `ready`, `wait`, `giveUp`, `key` and `diag` back through
 * another, and there was nothing on either end. A player who died got their
 * input taken away, the whole stock HUD hidden, and a black screen. This is that
 * missing end, and it is one channel -- `opx:downed:view` -- carrying a `kind`,
 * because that is the shape the seam already had.
 *
 * NOTHING HERE DECIDES ANYTHING, which is the same sentence `ProgressRoot.vue`
 * opens with and means something sharper on this surface: the two controls are a
 * respawn and a distress call, and both are the server's to grant. WAIT emits an
 * intent. GIVE UP does not even emit a decision -- it reports the state of a
 * BUTTON, down and still down and let go, and `client/main.lua` times the press
 * against its own clock and the server re-checks the two-minute delay against
 * its own. A page that lied about any of it would be arguing with two clocks it
 * cannot reach.
 *
 * EVERY WORD ON IT COMES FROM LUA. The seventeen keys under `medic.` are read
 * out of the active catalogue and handed over in the `config` payload, so this
 * file holds no English and no French; a key with no string renders AS the key,
 * which is loudly wrong on purpose (see `composables/useLocale`).
 *
 * -- WHAT IS TIMED, AND HOW ------------------------------------------------
 *
 * THREE CLOCKS, NONE OF THEM AUTHORITATIVE, and every one of them fed by a
 * DEADLINE rather than by a value Lua repeats:
 *
 *   the two-minute lock  `giveUpInMs` once, turned into an instant, counted down
 *                        by `useCountdown` and stopped dead at zero. Lua is
 *                        counting the same window and only its count unlocks
 *                        anything -- reaching zero here only stops drawing the
 *                        word "locked".
 *   DOWN FOR             `downForMs` once, turned into the instant the player
 *                        fell, and counted UP at 1Hz because it is drawn as
 *                        mm:ss and a faster tick would repaint the same two
 *                        digits.
 *   the 1.5s hold        a CSS transition of exactly `holdMs`, started on the
 *                        press. The browser interpolates it on the compositor,
 *                        so the fill is smooth whatever the page's frame rate is
 *                        doing, and nothing about the picture is on the wire.
 *
 * NOTHING ON THIS SURFACE CARRIES A FILTER, and that is not an oversight: two of
 * those clocks repaint while the player looks at them and the third repaints
 * every frame it fills. `.op-lift` is a `drop-shadow`, a filter gives the element
 * its own backing store, and a backing store re-rasterised on a ticking
 * countdown is the one thing `design-system/shapes.css` says never to do. The
 * chosen state is carried by `.op-frame.is-on` alone.
 */

/* -- the vocabulary --------------------------------------------------------
   The seventeen keys `client/main.lua` promises in `TEXT_KEYS`, named once so a
   typo is a build error in this file rather than a label that silently renders
   as a key on a screen the player cannot leave. */
const T = {
  eyebrow: 'medic.screen.eyebrow',
  title: 'medic.screen.title',
  subtitle: 'medic.screen.subtitle',
  vitals: 'medic.screen.vitals',
  bpm: 'medic.screen.bpm',
  down: 'medic.screen.down',
  signal: 'medic.screen.signal',
  signalOff: 'medic.screen.signalOff',
  signalOn: 'medic.screen.signalOn',
  waitLabel: 'medic.wait.label',
  waitHint: 'medic.wait.hint',
  waitActive: 'medic.wait.active',
  waitActiveHint: 'medic.wait.activeHint',
  giveUpLabel: 'medic.giveUp.label',
  giveUpHint: 'medic.giveUp.hint',
  giveUpLocked: 'medic.giveUp.locked',
  giveUpHolding: 'medic.giveUp.holding'
} as const

/** How often the button says it is still down. See `press` in `client/main.lua`. */
const BEAT_MS = 100

/** One frame at zero before a transition begins. `ProgressRoot.vue` pays the same. */
const FRAME_MS = 32

/** How long a refusal stays up. Lua sends the sentence; nothing here reads it. */
const NOTICE_MS = 5000

const open = ref(false)
/** Held aside by a suspender -- a downed staff member with the staff menu up. */
const aside = ref(false)
const waiting = ref(false)
const holdMs = ref(1500)
const notice = ref('')
const strings = ref<Record<string, string>>({})

/** Epoch milliseconds: when the player fell, and when GIVE UP unlocks (0 = now). */
const fellAt = ref(0)
const unlockAt = ref(0)

/** Now, at 1Hz, and only while the screen is up. Drives the DOWN FOR readout. */
const now = ref(Date.now())

const pressing = ref(false)
const filled = ref(false)

const lock = useCountdown(unlockAt)

let release: (() => void) | undefined
let beat: ReturnType<typeof setInterval> | undefined
let ticker: ReturnType<typeof setInterval> | undefined
let raise: ReturnType<typeof setTimeout> | undefined
let fade: ReturnType<typeof setTimeout> | undefined

/** A key's string, or the key. Loudly wrong beats invented English. */
function label(key: string): string {
  return strings.value[key] ?? key
}

/** `{time}` and friends, the same substitution `useLocale` does on the catalogue. */
function fillIn(template: string, vars: Record<string, string>): string {
  return template.replace(/\{(\w+)\}/g, (whole, name: string) => vars[name] ?? whole)
}

/** mm:ss, tabular by construction so a row does not jitter as digits change. */
function clock(ms: number): string {
  const total = Math.max(0, Math.ceil(ms / 1000))
  return `${String(Math.floor(total / 60)).padStart(2, '0')}:${String(total % 60).padStart(2, '0')}`
}

const locked = computed(() => !lock.done.value)
const canGiveUp = computed(() => open.value && !aside.value && !locked.value)
const downClock = computed(() => clock(Math.max(0, now.value - fellAt.value)))

/**
 * THE HEART RATE IS ZERO, and it is a reading rather than a decoration.
 *
 * Rule 8 of `ui/README.md`: a mono micro-label is part of the look and must state
 * something the surface actually knows, never invented chrome. Nothing sends this
 * page a pulse -- and it does not need one, because the one fact the screen is
 * built around is that the player is flatlining. A plausible decaying number
 * would be the invented chrome the rule bans; `00` is what the title says.
 */
const bpm = '00'

const giveUpTitle = computed(() =>
  pressing.value ? label(T.giveUpHolding) : label(T.giveUpLabel)
)

const giveUpHint = computed(() => {
  if (locked.value) return fillIn(label(T.giveUpLocked), { time: lock.clock.value })
  return label(T.giveUpHint)
})

function stopPress(report: boolean): void {
  if (beat !== undefined) clearInterval(beat)
  beat = undefined
  if (raise !== undefined) clearTimeout(raise)
  raise = undefined
  window.removeEventListener('pointerup', onPointerUp)
  window.removeEventListener('pointercancel', onPointerUp)
  window.removeEventListener('blur', onPointerUp)
  const was = pressing.value
  pressing.value = false
  filled.value = false
  // Only when there was a press to end: a `holding = false` for a button nobody
  // touched is a message the seam has to think about for nothing.
  if (was && report) emit('opx:downed:giveUp', { holding: false })
}

function onPointerUp(): void {
  stopPress(true)
}

/**
 * The press, as an intent repeated rather than as a duration claimed.
 *
 * A RELEASE OUTSIDE THE BUTTON IS STILL A RELEASE, which is why the listener goes
 * on the window: press, drag the pointer off the frame, let go, and the element
 * never sees the `pointerup` at all -- the button would sit there filling itself
 * against a finger that was no longer on it.
 */
function startPress(): void {
  if (!canGiveUp.value || pressing.value) return
  pressing.value = true
  filled.value = false
  emit('opx:downed:giveUp', { holding: true })
  beat = setInterval(() => emit('opx:downed:giveUp', { holding: true }), BEAT_MS)
  // ONE FRAME AT ZERO. A transition started in the frame the element gets its
  // class has no "from" to interpolate out of, so the fill snaps full and sits
  // there -- which on this control would read as a hold that had already finished.
  raise = setTimeout(() => { filled.value = true }, FRAME_MS)
  window.addEventListener('pointerup', onPointerUp)
  // A release this page never sees -- the window lost focus mid-hold, the engine
  // cancelled the pointer -- must end the hold too. Otherwise the beat kept saying
  // `holding: true` with no finger on anything, and Lua would carry out a give-up
  // the player had already let go of.
  window.addEventListener('pointercancel', onPointerUp)
  window.addEventListener('blur', onPointerUp)
}

function askWait(): void {
  if (!open.value || aside.value || waiting.value) return
  emit('opx:downed:wait', {})
}

function holdFocus(hold: boolean): void {
  if (hold) {
    if (release !== undefined) return
    release = acquireFocus({
      id: 'downed',
      // BEING DOWN IS NOT DISMISSIBLE, so Escape does nothing here on purpose.
      // Supplying a handler at all is the point: without one `bridge/focus.ts`
      // releases the owner on Escape, and Lua would take the keyboard straight
      // back on its next 500ms pass -- a cursor that blinks out and returns,
      // over a screen the player still cannot leave.
      onEscape: () => {}
    })
    return
  }
  if (release === undefined) return
  release()
  release = undefined
}

function blank(): void {
  open.value = false
  aside.value = false
  waiting.value = false
  notice.value = ''
  // THE TWO CLOCKS STOP WHERE THEY ARE, and are not zeroed. Zeroed, the fade-out
  // drew the DOWN FOR readout as `now - 0` -- tens of millions of minutes -- and the
  // give-up row flipped from its lock to "available" on the way out. `show` writes
  // both afresh, and a new deadline restarts the countdown on its own.
  lock.stop()
  stopPress(false)
  if (ticker !== undefined) clearInterval(ticker)
  ticker = undefined
  if (fade !== undefined) clearTimeout(fade)
  fade = undefined
}

function show(payload: Payload): void {
  const at = Date.now()
  const missing = Object.keys(strings.value).length === 0
  if (missing) {
    // The seam's own diagnostic channel rather than `opx:diag`: this is the one
    // failure that belongs to this module's log line, because the screen is
    // drawable and every word on it is a key. It happens if a `show` overtakes
    // the `config` published in answer to our `ready`.
    emit('opx:downed:diag', { text: 'show arrived before config; drawing keys' })
  }

  waiting.value = payload.waiting === true
  aside.value = payload.suspended === true
  holdMs.value = Math.max(0, num(payload.holdMs, 1500))
  fellAt.value = at - Math.max(0, num(payload.downForMs))

  // Zero is a deadline that has passed, which `useCountdown` reads as done and
  // stops counting -- so an unlocked screen carries no interval at all.
  const remaining = Math.max(0, num(payload.giveUpInMs))
  unlockAt.value = remaining > 0 ? at + remaining : 0

  now.value = at
  if (ticker === undefined) {
    // 1Hz. The readout is mm:ss; a faster tick repaints the same two digits.
    ticker = setInterval(() => { now.value = Date.now() }, 1000)
  }
  // A press cannot survive the state changing under it -- a revive and a second
  // death would otherwise arrive with the button still counted as down.
  if (aside.value) stopPress(false)
  open.value = true
}

useBridge('opx:downed:view', (payload: Payload) => {
  guard(
    'downed:view',
    () => {
      switch (text(payload.kind)) {
        case 'config': {
          const rows = table(payload.text)
          const next: Record<string, string> = {}
          for (const key of Object.keys(rows)) {
            const line = text(rows[key])
            if (line !== '') next[key] = line
          }
          strings.value = next
          break
        }
        case 'show':
          show(payload)
          break
        case 'hide':
          blank()
          holdFocus(false)
          break
        case 'notice': {
          notice.value = text(payload.text)
          if (fade !== undefined) clearTimeout(fade)
          fade = setTimeout(() => { notice.value = '' }, NOTICE_MS)
          break
        }
        case 'focus':
          holdFocus(payload.hold === true)
          break
      }
    },
    undefined
  )
})

/**
 * THE KEYBOARD IS OURS WHILE THIS IS UP, so every key mapping in the runtime is
 * inert -- the menu key included. Lua's `forwardKey` is the only way another
 * module hears one, and it accepts `F1`..`F99` and a single letter or digit, so
 * the shape is settled here rather than sending it everything and having it
 * refuse most of it.
 */
function onKeyDown(event: KeyboardEvent): void {
  if (!open.value || aside.value || event.defaultPrevented) return
  const key = event.key
  const named = /^F\d{1,2}$/.test(key) ? key : key.length === 1 ? key.toUpperCase() : ''
  if (!/^(F\d{1,2}|[A-Z0-9])$/.test(named)) return
  emit('opx:downed:key', { key: named })
}

onMounted(() => {
  window.addEventListener('keydown', onKeyDown)
  // The signal Lua waits for: it answers with the catalogue and the state, and
  // nothing is published to a view that has not reported ready.
  emit('opx:downed:ready', {})
})

onUnmounted(() => {
  window.removeEventListener('keydown', onKeyDown)
  blank()
  // A focus held across an unmount leaves the player unable to move.
  holdFocus(false)
})
</script>

<template>
  <div class="room op-ink" :class="{ open, aside }">
    <div class="stage op-plane">
      <div class="bay op-bay op-arete" data-augmented-ui="tr-clip bl-clip border">
        <div class="bay-inner op-interlace">
          <div class="head">
            <span class="eyebrow op-eyebrow">{{ label(T.eyebrow) }}</span>
            <h1>{{ label(T.title) }}</h1>
            <p class="subtitle op-copy">{{ label(T.subtitle) }}</p>
          </div>

          <!-- THE INSTRUMENTS. Three readouts and NOT three frames: a frame means
               "press this" (rule 2), and nothing here is pressable. They are
               label-over-value columns divided by the same 1px rule the head
               uses. -->
          <dl class="vitals">
            <div class="read">
              <dt class="op-eyebrow">{{ label(T.vitals) }}</dt>
              <dd>
                <svg class="glyph" viewBox="0 0 24 24" aria-hidden="true">
                  <path v-for="(d, at) in GLYPHS.heart" :key="at" :d="d" />
                </svg>
                <span class="figure op-value op-truncate">{{ bpm }}</span>
                <span class="unit op-eyebrow">{{ label(T.bpm) }}</span>
              </dd>
            </div>

            <div class="read">
              <dt class="op-eyebrow">{{ label(T.down) }}</dt>
              <dd>
                <svg class="glyph" viewBox="0 0 24 24" aria-hidden="true">
                  <path v-for="(d, at) in GLYPHS.clock" :key="at" :d="d" />
                </svg>
                <span class="figure op-value op-truncate">{{ downClock }}</span>
              </dd>
            </div>

            <div class="read">
              <dt class="op-eyebrow">{{ label(T.signal) }}</dt>
              <dd :class="{ live: waiting }">
                <svg class="glyph" viewBox="0 0 24 24" aria-hidden="true">
                  <path v-for="(d, at) in GLYPHS.bolt" :key="at" :d="d" />
                </svg>
                <span class="figure op-value op-truncate">
                  {{ waiting ? label(T.signalOn) : label(T.signalOff) }}
                </span>
              </dd>
            </div>
          </dl>

          <!-- THE TWO CHOICES. Both are controls, so both are closed boxes; the
               difference between them is entirely in their state, which is what
               rule 1 asks for -- a stroke going bright, never a block of colour. -->
          <div class="choices">
            <div
              class="choice op-frame"
              :class="{ 'is-on': waiting }"
              data-augmented-ui="tr-clip border"
              role="button"
              :aria-pressed="waiting"
              @click="askWait"
            >
              <svg class="mark" viewBox="0 0 24 24" aria-hidden="true">
                <path v-for="(d, at) in GLYPHS.heal" :key="at" :d="d" />
              </svg>
              <span class="choice-text">
                <span class="choice-label op-label op-truncate">
                  {{ waiting ? label(T.waitActive) : label(T.waitLabel) }}
                </span>
                <span class="choice-hint op-copy">
                  {{ waiting ? label(T.waitActiveHint) : label(T.waitHint) }}
                </span>
              </span>
            </div>

            <div
              class="choice give-up op-frame"
              :class="{ 'is-off': locked, 'is-on': pressing }"
              data-augmented-ui="tr-clip border"
              role="button"
              :aria-disabled="locked"
              @pointerdown.prevent="startPress"
              @pointerleave="stopPress(true)"
            >
              <!-- THE HOLD, as one transition of exactly `holdMs`. It is behind
                   the type and clipped by the frame's own chamfer, so it reads as
                   the control charging rather than as a bar bolted to it. -->
              <span
                class="charge"
                :style="{
                  transform: filled ? 'scaleX(1)' : 'scaleX(0)',
                  transitionDuration: pressing ? `${holdMs}ms` : '120ms'
                }"
              />
              <svg class="mark" viewBox="0 0 24 24" aria-hidden="true">
                <path v-for="(d, at) in GLYPHS.location" :key="at" :d="d" />
              </svg>
              <span class="choice-text">
                <span class="choice-label op-label op-truncate">{{ giveUpTitle }}</span>
                <span class="choice-hint op-copy">{{ giveUpHint }}</span>
              </span>
            </div>
          </div>

          <!-- A refusal, in the player's language, decided and worded by the
               server. It is a line of type and not a frame, for the same reason
               the readouts are not. -->
          <!-- ALWAYS IN THE LAYOUT, one line tall, and empty when there is nothing to
               say. Mounted only for a refusal, it grew a vertically centred bay by its
               own height: the whole panel, the button under the cursor with it, rose
               ~15px and dropped back five seconds later. -->
          <p class="notice op-copy" :aria-hidden="!notice">{{ notice }}</p>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   THE DOWN SCREEN -- red, outlined, untilted.

   It is `SpawnView`'s room -- a centred plane, one bay -- because it is
   the same kind of surface: a full-screen question the player cannot walk away
   from, over a world they may not touch. What is different is the weight. A
   spawn menu is offered; this is the end of a life, so the wash is heavier, the
   title is the hero size, and the instruments above the controls are there to
   say that the body is still being measured.

   NO TILT: a centred plane rotated about its own middle is paper on a spindle,
   so the stage carries `.op-plane` and no `.op-anchor-*`.

   NO FILTER, ANYWHERE. Two readouts tick while the player watches them and the
   charge repaints every frame it fills; `.op-lift` would give each its own
   backing store to re-rasterise. The chosen state is `.op-frame.is-on` alone.
   ========================================================================== */

.room {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  opacity: 0;
  pointer-events: none;
  transition: opacity var(--op-dur) var(--op-ease);
}

.room.open {
  opacity: 1;
  pointer-events: auto;
}

/* HELD ASIDE. A suspender -- the staff menu over a downed staff member -- gets
   the input back from Lua, so the layer is already inert; this is the picture
   catching up with that. Not `display: none`: the player is still dead and the
   screen is still theirs, it is just not the thing they are using. */
.room.aside {
  opacity: 0.12;
  pointer-events: none;
}

/* NO WASH. There was a full-screen veil here at 84% of the plate colour, and
   the owner asked for it gone: being dead is the one state where what is behind
   the panel -- the street, whoever is standing over you -- is worth more than
   the panel's legibility. The element is gone with it rather than left at zero
   alpha; it was `inset: 0` over the whole surface, and an invisible layer that
   still occupies the screen is the kind of thing that gets blamed for stray
   clicks a year later. Its `--op-downed-veil` knob was never defined anywhere,
   so nothing else reads it back. */
.stage {
  position: relative;
  display: flex;
  width: min(720px, calc(100vw - var(--op-inset-x) * 2));
  max-height: calc(100vh - var(--op-inset-y) * 2);
}

.bay {
  position: relative;
  flex: 1;
  min-width: 0;
  background: rgba(var(--op-plate-rgb), var(--op-plate-a));
}

.bay-inner {
  position: relative;
  z-index: 1;
  display: flex;
  flex-direction: column;
  min-height: 0;
}

/* =============================================================================
   THE HEAD -- the one sentence the screen exists to say.
   ========================================================================== */
.head {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  padding: var(--op-space-5) calc(var(--op-space-5) + var(--op-cut-lg)) var(--op-space-4)
    calc(var(--op-space-5) + var(--op-rule));
  border-bottom: 1px solid var(--op-red-idle);
}

/* No `//` device in front of it: the string Lua sends already carries one, and
   two would be the surface talking over its own content. */
.eyebrow {
  color: var(--op-red-deep);
}

.head h1 {
  margin: 0;
  font: 700 var(--op-fs-hero) / 1 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  text-transform: uppercase;
  color: var(--op-red);
}

.subtitle {
  margin: 0;
  color: var(--op-text-dim);
}

/* =============================================================================
   THE INSTRUMENTS -- three readouts, no frames. A 1px rule divides them, which
   is a separator and not an enclosure.
   ========================================================================== */
.vitals {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: var(--op-space-4);
  margin: 0;
  padding: var(--op-space-3) calc(var(--op-space-5) + var(--op-cut-lg)) var(--op-space-3)
    calc(var(--op-space-5) + var(--op-rule));
  border-bottom: 1px solid var(--op-red-idle);
}

.read {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-2);
  min-width: 0;
}

.read dt {
  color: var(--op-text-faint);
}

.read dd {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  margin: 0;
  min-width: 0;
  color: var(--op-red-text);
}

.glyph {
  flex: none;
  width: 14px;
  height: 14px;
  fill: none;
  stroke: currentcolor;
  stroke-width: 1.9;
  stroke-linecap: round;
  stroke-linejoin: round;
}

/* THE CUT IS `.op-truncate` ON THE ELEMENT. Written out here it was missing
   `min-width: 0`, and `.figure`'s parent -- the `dd`, a plain flex row -- does
   not supply one, so a reading long enough to need the ellipsis pushed the unit
   out of the row instead of being cut. Only the size is this surface's own. */
.figure {
  font-size: var(--op-fs-body);
}

.unit {
  color: var(--op-text-faint);
}

/* BROADCASTING is the one live reading on the screen, so it is the one that
   climbs the ladder: a rung up in luminance, and nothing else moves. */
.read dd.live {
  color: var(--op-red);
}

/* =============================================================================
   THE TWO CHOICES -- side by side where there is room, stacked where there is
   not. Equal width on purpose: neither is the recommended one.
   ========================================================================== */
.choices {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
  gap: var(--op-space-2);
  padding: var(--op-space-4) calc(var(--op-space-4) + var(--op-cut-lg)) var(--op-space-4)
    calc(var(--op-space-4) + var(--op-rule));
}

.choice {
  position: relative;
  display: flex;
  align-items: center;
  gap: var(--op-space-3);
  min-width: 0;
  /* The right edge pays for the chamfer, so a long label never runs under it. */
  padding: var(--op-space-3) calc(var(--op-space-4) + var(--op-cut-sm)) var(--op-space-3)
    var(--op-space-4);
  cursor: pointer;
  user-select: none;
  transition: color var(--op-dur-fast) linear;
}

.choice.is-off {
  cursor: default;
}

.mark {
  position: relative;
  z-index: 1;
  flex: none;
  width: 22px;
  height: 22px;
  fill: none;
  stroke: currentcolor;
  stroke-width: 1.7;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.choice-text {
  position: relative;
  z-index: 1;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  min-width: 0;
}

.choice-hint {
  color: var(--op-text-dim);
  /* It carries the give-up lock's mm:ss, re-drawn every second in a proportional
     face: the clock's width changed with its digits and the line shivered. */
  font-variant-numeric: tabular-nums;
}

.choice.is-off .choice-hint {
  color: var(--op-text-faint);
}

/* --- THE CHARGE --------------------------------------------------------------
   The hold, drawn as the control filling up behind its own type. `scaleX` from
   the left and never `width`: a width is layout and this moves for a second and
   a half at a stretch, while a transform is composited. It is the ground going
   lit rather than a second colour -- rule 1 -- so what fills is the plate, not
   the accent.

   LINEAR, and the duration is the payload's. An eased charge lies about how much
   longer the player has to hold, which is the only thing it is for. */
.charge {
  position: absolute;
  inset: 0;
  z-index: 0;
  background: var(--op-plate-lit);
  transform-origin: left center;
  transform: scaleX(0);
  transition-property: transform;
  transition-timing-function: linear;
  pointer-events: none;
}

/* =============================================================================
   THE REFUSAL -- the server's sentence, under the controls it refused.
   ========================================================================== */
.notice {
  margin: 0;
  /* The line is reserved whether or not it is spoken in: see the template. */
  min-height: 1.4em;
  padding: 0 calc(var(--op-space-5) + var(--op-cut-lg)) var(--op-space-4)
    calc(var(--op-space-5) + var(--op-rule));
  color: var(--op-alarm);
  font-family: var(--op-font-mono);
  letter-spacing: var(--op-track-label);
}
</style>
