<script setup lang="ts">
import { computed, onUnmounted, ref, watch, onMounted } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { records, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE HANDSET -- a radio, projected, on the right edge of the screen.
 *
 * THE OWNER: "pour le script radio enfois de le faire en menu fait un vrais style
 * de radio mais holograpique qui pop a droite de l'ecran". It was a menu: a power
 * toggle and one row per channel with a sub-menu of join / talk here / mute. The
 * verbs are the same and so is every request; what changed is the object. A
 * radio has a screen that says which channel the knob is on, a knob that turns
 * through them, a few keys under the screen and a side key you hold to talk --
 * so that is what is drawn, in light, standing off the edge it is anchored to.
 *
 * THE KNOB IS THE PAGE'S, EVERYTHING ELSE IS LUA'S. Which channel the screen is
 * showing is local (`cursor`) -- turning a dial asks nobody anything. Joining,
 * leaving, talking on it, muting it and the power are requests, and the screen
 * only changes when the state comes back from the server
 * (`modules/radio/client/main.lua`).
 *
 * THE SIDE KEY IS THE TALK KEY. Holding it sends the same `talk` the keyboard
 * key does; the server grants it on the same terms, and the antenna tip lights
 * only once it has (`tx` comes back on the payload, never guessed here).
 */

const { t } = useLocale()

interface Row {
  key: string
  label: string
  short: string
  joined: boolean
  muted: boolean
  active: boolean
  auto: boolean
}

const open = ref(false)
const anchor = ref('right')
const power = ref(false)
const handset = ref(true)
const needsHandset = ref(false)
const tx = ref(false)
const channels = ref<Row[]>([])

/** The channel the knob is on: a KEY, so a list that reorders keeps it. */
const cursorKey = ref<string | null>(null)

onMounted(() => {
  emit('opx:radio:ready', {})
})

useBridge('opx:radio:holo', (payload: Payload) => {
  guard('radio:holo', () => {
    const wasOpen = open.value
    open.value = payload.open === true
    if (text(payload.anchor) !== '') anchor.value = text(payload.anchor)
    power.value = payload.power === true
    handset.value = payload.handset !== false
    needsHandset.value = payload.needsHandset === true
    tx.value = payload.tx === true
    channels.value = records(payload.channels)
      .map((row) => ({
        key: text(row.key),
        label: text(row.label, text(row.key)),
        short: text(row.short, text(row.key)),
        joined: row.joined === true,
        muted: row.muted === true,
        active: row.active === true,
        auto: row.auto === true
      }))
      .filter((row) => row.key !== '')
    // A handset just taken out shows the channel it talks on; one already in
    // hand keeps whatever the player turned the knob to.
    const known = channels.value.some((row) => row.key === cursorKey.value)
    if (!wasOpen || !known) {
      const active = channels.value.find((row) => row.active) ?? channels.value[0]
      cursorKey.value = active ? active.key : null
    }
  }, undefined)
})

const index = computed(() => channels.value.findIndex((row) => row.key === cursorKey.value))
const current = computed<Row | null>(() => (index.value >= 0 ? channels.value[index.value] : null))

/** Why the screen cannot show a channel, or null when it can. */
const blank = computed<string | null>(() => {
  if (needsHandset.value && !handset.value) return t('radio.holo.noHandset')
  if (!power.value) return t('radio.holo.noPower')
  if (channels.value.length === 0) return t('radio.holo.none')
  return null
})

const live = computed(() => blank.value === null && current.value !== null)

/** The state word on the screen, in the same four words the menu used. */
const status = computed(() => {
  const row = current.value
  if (row === null || !row.joined) return t('radio.status.off')
  if (row.active && tx.value) return t('radio.status.active')
  if (row.muted) return t('radio.status.muted')
  return t('radio.status.listening')
})

/** Signal: four bars, lit by how much of the channel this radio is on. */
const bars = computed(() => {
  const row = current.value
  if (!live.value || row === null) return 0
  if (!row.joined) return 1
  if (row.muted) return 2
  return row.active ? 4 : 3
})

// ── the knob ─────────────────────────────────────────────────────────────────

function turn(step: number): void {
  const count = channels.value.length
  if (count === 0) return
  const at = index.value < 0 ? 0 : index.value
  cursorKey.value = channels.value[(at + step + count) % count].key
}

function onWheel(event: WheelEvent): void {
  turn(event.deltaY > 0 ? 1 : -1)
}

/** The dial's notch, a tenth of a turn per channel. */
const notch = computed(() => `rotate(${Math.max(index.value, 0) * 36}deg)`)

// ── the keys ─────────────────────────────────────────────────────────────────

function ask(verb: string, channel?: string, on?: boolean): void {
  const payload: Payload = { verb }
  if (channel !== undefined) payload.channel = channel
  if (on !== undefined) payload.on = on
  emit('opx:radio:request', payload)
}

function togglePower(): void {
  ask('power', undefined, !power.value)
}

function toggleJoin(): void {
  const row = current.value
  if (!live.value || row === null) return
  ask(row.joined ? 'leave' : 'join', row.key)
}

function selectRow(): void {
  const row = current.value
  if (!live.value || row === null || !row.joined || row.active) return
  ask('select', row.key)
}

function toggleMute(): void {
  const row = current.value
  if (!live.value || row === null || !row.joined) return
  ask('mute', row.key, !row.muted)
}

// ── the side key ─────────────────────────────────────────────────────────────

const pressing = ref(false)

function listenForRelease(active: boolean): void {
  if (active) {
    window.addEventListener('pointerup', pttUp)
    window.addEventListener('pointercancel', pttUp)
    window.addEventListener('blur', pttUp)
  } else {
    window.removeEventListener('pointerup', pttUp)
    window.removeEventListener('pointercancel', pttUp)
    window.removeEventListener('blur', pttUp)
  }
}

function pttDown(event: PointerEvent): void {
  if (event.button !== 0 || pressing.value) return
  pressing.value = true
  // A focus change need not produce pointerleave or pointerup on this button.
  // Keep a release path while held so switching windows cannot leave it keyed.
  listenForRelease(true)
  emit('opx:radio:talk', { on: true })
}

function pttUp(): void {
  if (!pressing.value) return
  pressing.value = false
  listenForRelease(false)
  emit('opx:radio:talk', { on: false })
}

// ── the screen as a whole ────────────────────────────────────────────────────

function close(): void {
  pttUp()
  emit('opx:radio:close', {})
}

function onKey(event: KeyboardEvent): void {
  if (!open.value) return
  if (event.key === 'ArrowUp' || event.key === 'ArrowLeft') {
    event.preventDefault()
    turn(-1)
  } else if (event.key === 'ArrowDown' || event.key === 'ArrowRight') {
    event.preventDefault()
    turn(1)
  }
}

/* THE PAGE HOLDS 'radio' WHILE THE HANDSET IS UP, mirroring Lua's own
   `AcquireFocus('radio')` -- the reconcile in core/client/ui.lua treats the page's
   stack as the truth, and an owner the page never announced is wiped the next time
   anything else lets go. See `calls/HoloRoot.vue`, which shipped that fault. */
let release: (() => void) | undefined

watch(open, (isOpen) => {
  if (isOpen && release === undefined) {
    release = acquireFocus({ id: 'radio', onEscape: close })
    window.addEventListener('keydown', onKey)
  } else if (!isOpen && release !== undefined) {
    pttUp()
    release()
    release = undefined
    window.removeEventListener('keydown', onKey)
  }
})

onUnmounted(() => {
  // A transmission or a focus held across an unmount is a stuck key and a
  // player who cannot move.
  pttUp()
  release?.()
  release = undefined
  window.removeEventListener('keydown', onKey)
})

const side = computed(() =>
  anchor.value.endsWith('left') ? 'is-left' : anchor.value.endsWith('right') ? 'is-right' : 'is-centre'
)

/** Twelve bars on the scope: read off nothing, so they are drawn, not said. */
const WAVE = 12
</script>

<template>
  <div v-if="open" class="radio op-ink" :class="['anchor-' + anchor, side]">
    <div class="rig">
      <!-- The emitter on the edge the projection is anchored to, and the beam
           it throws. Gradients and a clip, nothing that repaints. -->
      <div class="emitter" aria-hidden="true"><span class="node"></span><span class="node"></span></div>
      <div class="beam" aria-hidden="true"></div>

      <div class="device" :class="{ dead: !power, tx }">
        <!-- ── the top of the handset: antenna, power knob, channel dial ── -->
        <div class="crown">
          <div class="antenna" aria-hidden="true"><span class="tip" :class="{ lit: tx }"></span></div>
          <button
            type="button"
            class="knob pwr"
            :class="{ on: power }"
            :title="t('radio.holo.power')"
            @click="togglePower"
          >
            <span class="knob-face"></span>
            <span class="knob-tag op-eyebrow">{{ t('radio.holo.power') }}</span>
          </button>
          <button
            type="button"
            class="knob dial"
            :class="{ off: !live }"
            :title="t('radio.holo.dial')"
            @click="turn(1)"
            @contextmenu.prevent="turn(-1)"
            @wheel.prevent="onWheel"
          >
            <span class="knob-face" :style="{ transform: notch }"><i></i></span>
            <span class="knob-tag op-eyebrow">{{ t('radio.holo.dial') }}</span>
          </button>
        </div>

        <div class="body op-bay" data-augmented-ui="tr-clip bl-clip border">
          <!-- ── the screen ──────────────────────────────────────────── -->
          <div class="screen" :class="{ blank: !live }">
            <div class="screen-top op-eyebrow">
              <span>{{ t('radio.title') }}</span>
              <span v-if="live" class="ch">{{ t('radio.holo.channel', { n: index + 1, total: channels.length }) }}</span>
              <span class="signal" aria-hidden="true">
                <i v-for="bar in 4" :key="bar" :class="{ on: bar <= bars }"></i>
              </span>
            </div>

            <template v-if="live && current">
              <p class="freq op-truncate">{{ current.short }}</p>
              <p class="name op-copy op-truncate">{{ current.label }}</p>
              <div class="screen-foot op-eyebrow">
                <span class="state" :class="{ hot: current.active && tx, quiet: !current.joined || current.muted }">
                  {{ status }}
                </span>
                <span v-if="current.active" class="tag">{{ t('radio.holo.onKey') }}</span>
                <span v-if="current.auto" class="tag">{{ t('radio.holo.auto') }}</span>
              </div>
              <div class="scope" :class="{ hot: current.active && tx, idle: !current.joined || current.muted }" aria-hidden="true">
                <i v-for="bar in WAVE" :key="bar" :style="{ animationDelay: `${bar * -97}ms` }"></i>
              </div>
            </template>
            <p v-else class="blank-copy op-label">{{ blank }}</p>
          </div>

          <!-- ── the channel strip: one tick per channel, the knob's in red ── -->
          <div v-if="live" class="strip">
            <button type="button" class="step" :title="t('radio.holo.prev')" @click="turn(-1)">&#9664;</button>
            <div class="ticks">
              <button
                v-for="row in channels"
                :key="row.key"
                type="button"
                class="tick"
                :class="{ at: row.key === cursorKey, joined: row.joined, active: row.active }"
                :title="row.label"
                @click="cursorKey = row.key"
              ></button>
            </div>
            <button type="button" class="step" :title="t('radio.holo.next')" @click="turn(1)">&#9654;</button>
          </div>

          <!-- ── the keys under the screen ──────────────────────────────── -->
          <div class="keys">
            <button
              type="button"
              class="key op-eyebrow"
              :class="{ off: !live, lit: current?.joined }"
              :disabled="!live"
              @click="toggleJoin"
            >
              {{ current?.joined ? t('radio.holo.leave') : t('radio.holo.join') }}
            </button>
            <button
              type="button"
              class="key op-eyebrow"
              :class="{ off: !live || !current?.joined, lit: current?.active }"
              :disabled="!live || !current?.joined || current?.active"
              @click="selectRow"
            >
              {{ current?.active ? t('radio.holo.selected') : t('radio.holo.select') }}
            </button>
            <button
              type="button"
              class="key op-eyebrow"
              :class="{ off: !live || !current?.joined, lit: current?.muted }"
              :disabled="!live || !current?.joined"
              @click="toggleMute"
            >
              {{ current?.muted ? t('radio.holo.unmute') : t('radio.holo.mute') }}
            </button>
          </div>

          <!-- The speaker. A grille is the radio's face; it says nothing. -->
          <div class="grille" aria-hidden="true"></div>

          <div class="foot">
            <button type="button" class="shut op-eyebrow" @click="close">{{ t('radio.holo.close') }}</button>
          </div>
        </div>

        <!-- ── the side key ────────────────────────────────────────────── -->
        <button
          type="button"
          class="ptt"
          :class="{ held: pressing, hot: tx }"
          :title="t('radio.holo.ptt')"
          @pointerdown="pttDown"
          @pointerup="pttUp"
          @pointercancel="pttUp"
          @pointerleave="pttUp"
        >
          <span class="ptt-tag op-eyebrow">{{ t('radio.holo.ptt') }}</span>
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   A HANDSET MADE OF LIGHT, standing off the right edge.

   Built the way `calls/HoloRoot.vue` builds its projection: no plate behind the
   type, legibility from the type's own glow, and the 3D from one `perspective`
   and one tilt -- the house tilt, `--op-tilt`, about the edge the surface is
   anchored to (README, contract rule 5). No filters: the scope and the antenna
   tip animate, and a filter would give each a backing store per frame.
   ========================================================================== */
.radio {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: flex-end;
  padding: var(--op-inset-y) var(--op-inset-x);
  pointer-events: none;
  perspective: 1100px;
}

/* The nine positions of `lib/shared/anchors.lua`, as on the holocall. */
.anchor-top-left { align-items: flex-start; justify-content: flex-start; }
.anchor-top-center { align-items: flex-start; justify-content: center; }
.anchor-top-right { align-items: flex-start; justify-content: flex-end; }
.anchor-left { align-items: center; justify-content: flex-start; }
.anchor-center { align-items: center; justify-content: center; }
.anchor-right { align-items: center; justify-content: flex-end; }
.anchor-bottom-left { align-items: flex-end; justify-content: flex-start; }
.anchor-bottom-center { align-items: flex-end; justify-content: center; }
.anchor-bottom-right { align-items: flex-end; justify-content: flex-end; }

.is-right { perspective-origin: 100% 50%; }
.is-left { perspective-origin: 0% 50%; }

/* --- the rig: the tilt, and the pop -------------------------------------- */
.rig {
  position: relative;
  display: flex;
  align-items: center;
  transform-style: preserve-3d;
  transform-origin: right center;
  transform: rotateY(calc(var(--op-tilt) * -1));
  animation: radio-pop var(--op-dur-slow) var(--op-ease) both;
}

.is-left .rig {
  flex-direction: row-reverse;
  transform-origin: left center;
  transform: rotateY(var(--op-tilt));
  animation-name: radio-pop-left;
}

.is-centre .rig {
  transform: none;
  animation-name: radio-rise;
}

.is-centre .emitter,
.is-centre .beam {
  display: none;
}

/* --- the emitter and the beam -------------------------------------------- */
.emitter {
  order: 2;
  position: relative;
  width: 2px;
  height: 340px;
  margin-left: 46px;
  background: linear-gradient(
    to bottom,
    transparent,
    rgba(var(--op-red-rgb), 0.85) 30%,
    rgba(var(--op-red-rgb), 0.85) 70%,
    transparent
  );
  box-shadow: 0 0 18px rgba(var(--op-red-rgb), 0.45);
}

.is-left .emitter {
  margin-left: 0;
  margin-right: 46px;
}

.node {
  position: absolute;
  left: -3px;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--op-red-hi);
  box-shadow: 0 0 10px var(--op-red-glow);
}

.node:first-child { top: 30%; }
.node:last-child { top: 70%; }

.beam {
  position: absolute;
  top: 50%;
  right: 0;
  width: 120px;
  height: 520px;
  margin-top: -260px;
  pointer-events: none;
  background: linear-gradient(
    to left,
    rgba(var(--op-red-rgb), 0.18),
    rgba(var(--op-red-rgb), 0.05) 55%,
    transparent
  );
  clip-path: polygon(100% 34%, 100% 66%, 0% 100%, 0% 0%);
}

.is-left .beam {
  right: auto;
  left: 0;
  transform: scaleX(-1);
}

/* --- the handset --------------------------------------------------------- */
.device {
  order: 1;
  position: relative;
  width: 276px;
  pointer-events: auto;
  color: var(--op-red-text);
}

.crown {
  position: relative;
  display: flex;
  align-items: flex-end;
  gap: var(--op-space-3);
  height: 92px;
  padding-left: var(--op-space-4);
}

/* The antenna: a stub on the far side, its tip the on-air light. */
.antenna {
  position: absolute;
  right: 34px;
  bottom: 0;
  width: 14px;
  height: 88px;
  border: 1px solid rgba(var(--op-red-rgb), 0.55);
  border-bottom: 0;
  background: repeating-linear-gradient(
    to bottom,
    rgba(var(--op-red-rgb), 0.18) 0 2px,
    transparent 2px 7px
  );
}

.tip {
  position: absolute;
  top: -7px;
  left: 50%;
  width: 10px;
  height: 10px;
  margin-left: -5px;
  border-radius: 50%;
  border: 1px solid rgba(var(--op-red-rgb), 0.6);
}

.tip.lit {
  background: var(--op-red-hi);
  box-shadow: 0 0 14px var(--op-red-hi), 0 0 30px var(--op-red-glow);
  animation: radio-blink 0.9s ease-in-out infinite;
}

.knob {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: var(--op-space-1);
  padding: 0;
  border: 0;
  background: none;
  color: var(--op-text-faint);
  cursor: pointer;
}

.knob-face {
  position: relative;
  display: block;
  width: 34px;
  height: 34px;
  border-radius: 50%;
  border: 1px solid rgba(var(--op-red-rgb), 0.5);
  background: repeating-conic-gradient(rgba(var(--op-red-rgb), 0.22) 0 6deg, transparent 6deg 18deg);
  transition: transform var(--op-dur) var(--op-ease), border-color var(--op-dur-fast);
}

/* The dial's pointer, which is what turns. */
.knob-face i {
  position: absolute;
  top: 3px;
  left: 50%;
  width: 2px;
  height: 11px;
  margin-left: -1px;
  background: var(--op-red-hi);
}

.knob:hover .knob-face {
  border-color: var(--op-red);
}

.knob.pwr.on .knob-face {
  border-color: var(--op-red);
  box-shadow: 0 0 14px rgba(var(--op-red-rgb), 0.4), inset 0 0 8px rgba(var(--op-red-rgb), 0.35);
}

.knob.pwr.on {
  color: var(--op-red);
}

.knob.off {
  opacity: 0.45;
}

/* --- the body ------------------------------------------------------------ */
.body {
  --aug-border-bg: linear-gradient(225deg, var(--op-red-hi) 0%, var(--op-red-hi) 30%, var(--op-red-idle) 60%);
  padding: var(--op-space-4) var(--op-space-4) var(--op-space-3);
  /* The projection's grain instead of a ground: a scanline wash, faint. */
  background: repeating-linear-gradient(to bottom, rgba(var(--op-red-rgb), 0.06) 0 1px, transparent 1px 3px);
}

.is-left .body {
  --aug-border-bg: linear-gradient(135deg, var(--op-red-hi) 0%, var(--op-red-hi) 30%, var(--op-red-idle) 60%);
}

/* --- the screen ---------------------------------------------------------- */
.screen {
  position: relative;
  min-height: 138px;
  padding: var(--op-space-2) var(--op-space-3);
  border: 1px solid rgba(var(--op-red-rgb), 0.45);
  background:
    repeating-linear-gradient(to bottom, rgba(var(--op-red-rgb), 0.1) 0 1px, transparent 1px 2px),
    radial-gradient(ellipse at 50% 40%, rgba(var(--op-red-rgb), 0.14), transparent 70%);
  box-shadow: inset 0 0 22px rgba(var(--op-red-rgb), 0.18);
  overflow: hidden;
  animation: radio-flicker var(--op-enter-ms) var(--op-stutter) both;
}

.screen-top {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  color: var(--op-text-faint);
}

.ch {
  color: var(--op-red-text);
}

.signal {
  display: flex;
  align-items: flex-end;
  gap: 2px;
  height: 9px;
  margin-left: auto;
}

.signal i {
  width: 3px;
  background: rgba(var(--op-red-rgb), 0.2);
}

.signal i:nth-child(1) { height: 3px; }
.signal i:nth-child(2) { height: 5px; }
.signal i:nth-child(3) { height: 7px; }
.signal i:nth-child(4) { height: 9px; }

.signal i.on {
  background: var(--op-red);
}

/* The frequency tag: the one big thing on the radio, in the display face. */
.freq {
  margin: var(--op-space-2) 0 0;
  font-family: var(--op-font-display);
  font-size: var(--op-fs-head);
  font-weight: 700;
  line-height: 1;
  letter-spacing: 0.08em;
  color: var(--op-red);
  text-shadow: var(--op-ink), 0 0 16px var(--op-red-glow);
}

.name {
  margin: var(--op-space-1) 0 0;
  color: var(--op-red-text);
}

.screen-foot {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  margin-top: var(--op-space-2);
}

.state {
  color: var(--op-red);
}

.state.quiet {
  color: var(--op-text-faint);
}

.state.hot {
  color: var(--op-red-hi);
  text-shadow: var(--op-ink), 0 0 10px var(--op-red-hi);
}

.tag {
  padding: 1px 4px;
  border: 1px solid rgba(var(--op-red-rgb), 0.4);
  color: var(--op-red-text);
}

/* The scope: twelve bars breathing while the channel is heard, racing while
   this radio is on air, flat when it is off or muted. Only `transform` moves. */
.scope {
  display: flex;
  align-items: center;
  gap: 3px;
  height: 22px;
  margin-top: var(--op-space-2);
}

.scope i {
  flex: 1;
  height: 100%;
  background: rgba(var(--op-red-rgb), 0.55);
  transform-origin: center;
  animation: radio-wave 1.4s ease-in-out infinite;
}

.scope.hot i {
  background: var(--op-red-hi);
  animation-duration: 0.42s;
}

.scope.idle i {
  animation: none;
  transform: scaleY(0.08);
  background: rgba(var(--op-red-rgb), 0.3);
}

.blank-copy {
  margin: var(--op-space-6) 0 0;
  text-align: center;
  color: var(--op-text-faint);
}

/* --- the channel strip --------------------------------------------------- */
.strip {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  margin-top: var(--op-space-3);
}

.step {
  border: 0;
  padding: var(--op-space-1);
  background: none;
  color: var(--op-text-faint);
  font-size: var(--op-fs-meta);
  cursor: pointer;
}

.step:hover {
  color: var(--op-red);
}

.ticks {
  display: flex;
  flex: 1;
  gap: 3px;
}

.tick {
  flex: 1;
  height: 8px;
  padding: 0;
  border: 1px solid rgba(var(--op-red-rgb), 0.25);
  background: none;
  cursor: pointer;
}

.tick.joined {
  border-color: rgba(var(--op-red-rgb), 0.6);
  background: rgba(var(--op-red-rgb), 0.18);
}

.tick.active {
  background: rgba(var(--op-red-rgb), 0.45);
}

.tick.at {
  border-color: var(--op-red-hi);
  box-shadow: 0 0 8px var(--op-red-glow);
}

/* --- the keys ------------------------------------------------------------ */
.keys {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: var(--op-space-2);
  margin-top: var(--op-space-3);
}

.key {
  min-height: 30px;
  padding: var(--op-space-1);
  border: 1px solid rgba(var(--op-red-rgb), 0.5);
  border-radius: 2px;
  background: none;
  color: var(--op-red-text);
  cursor: pointer;
  transition: border-color var(--op-dur-fast), box-shadow var(--op-dur-fast), color var(--op-dur-fast);
}

.key:hover:not(:disabled) {
  border-color: var(--op-red);
  color: var(--op-red);
  box-shadow: 0 0 14px rgba(var(--op-red-rgb), 0.3);
}

.key.lit {
  border-color: var(--op-red);
  color: var(--op-red);
  box-shadow: inset 0 0 10px rgba(var(--op-red-rgb), 0.3);
}

.key.off {
  border-color: var(--op-off-line);
  color: var(--op-text-faint);
  cursor: default;
}

/* --- the speaker and the foot -------------------------------------------- */
.grille {
  height: 46px;
  margin-top: var(--op-space-3);
  border-radius: 3px;
  background:
    radial-gradient(circle, rgba(var(--op-red-rgb), 0.38) 1px, transparent 1.6px) 0 0 / 7px 7px;
  -webkit-mask-image: linear-gradient(to right, transparent, #000 15%, #000 85%, transparent);
  mask-image: linear-gradient(to right, transparent, #000 15%, #000 85%, transparent);
}

.foot {
  display: flex;
  justify-content: flex-end;
  margin-top: var(--op-space-2);
}

.shut {
  border: 0;
  background: none;
  color: var(--op-text-faint);
  cursor: pointer;
}

.shut:hover {
  color: var(--op-red);
}

/* --- the side key -------------------------------------------------------- */
.ptt {
  position: absolute;
  top: 150px;
  left: -16px;
  width: 12px;
  height: 92px;
  padding: 0;
  border: 1px solid rgba(var(--op-red-rgb), 0.55);
  border-right: 0;
  background: repeating-linear-gradient(to bottom, rgba(var(--op-red-rgb), 0.25) 0 2px, transparent 2px 5px);
  cursor: pointer;
  transition: transform var(--op-dur-fast), border-color var(--op-dur-fast);
}

.is-left .ptt {
  left: auto;
  right: -16px;
  border-right: 1px solid rgba(var(--op-red-rgb), 0.55);
  border-left: 0;
}

.ptt-tag {
  position: absolute;
  top: 50%;
  right: 18px;
  white-space: nowrap;
  color: var(--op-text-faint);
  transform: translateY(-50%);
  opacity: 0;
  transition: opacity var(--op-dur);
}

.is-left .ptt-tag {
  right: auto;
  left: 18px;
}

.ptt:hover .ptt-tag,
.ptt.held .ptt-tag {
  opacity: 1;
}

.ptt:hover {
  border-color: var(--op-red);
}

.ptt.held {
  transform: translateX(3px);
  border-color: var(--op-red);
}

.is-left .ptt.held {
  transform: translateX(-3px);
}

.ptt.hot {
  border-color: var(--op-red-hi);
  box-shadow: 0 0 14px var(--op-red-glow);
}

/* --- a dead radio -------------------------------------------------------- */
.device.dead .screen {
  border-color: var(--op-off-line);
  box-shadow: none;
  background: repeating-linear-gradient(to bottom, rgba(var(--op-red-rgb), 0.04) 0 1px, transparent 1px 2px);
}

.device.dead .grille,
.device.dead .antenna {
  opacity: 0.4;
}

/* --- motion -------------------------------------------------------------- */
/* The projection arrives off the edge it stands on. */
@keyframes radio-pop {
  from {
    opacity: 0;
    transform: rotateY(calc(var(--op-tilt) * -1)) translateX(36px) scaleY(0.86);
  }
  to {
    opacity: 1;
    transform: rotateY(calc(var(--op-tilt) * -1));
  }
}

@keyframes radio-pop-left {
  from {
    opacity: 0;
    transform: rotateY(var(--op-tilt)) translateX(-36px) scaleY(0.86);
  }
  to {
    opacity: 1;
    transform: rotateY(var(--op-tilt));
  }
}

@keyframes radio-rise {
  from {
    opacity: 0;
    transform: translateY(12px) scaleY(0.9);
  }
  to {
    opacity: 1;
    transform: none;
  }
}

/* The screen catches on the house stutter, as every surface does. */
@keyframes radio-flicker {
  from {
    opacity: 0;
  }
  to {
    opacity: 1;
  }
}

@keyframes radio-wave {
  0%,
  100% {
    transform: scaleY(0.18);
  }
  50% {
    transform: scaleY(1);
  }
}

@keyframes radio-blink {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.45;
  }
}

@media (prefers-reduced-motion: reduce) {
  .rig,
  .screen,
  .scope i,
  .tip.lit {
    animation: none;
  }
}
</style>
