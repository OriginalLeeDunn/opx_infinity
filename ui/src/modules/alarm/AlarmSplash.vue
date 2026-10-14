<script setup lang="ts">
import { onUnmounted, ref } from 'vue'
import { list, num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { playClip } from '@/modules/notify/stinger'

/**
 * THE MAXTAC ALARM -- the squad's whole screen when somebody goes cyberpsycho
 * (`modules/ncpd`, `ALERTS.ALARM` in config/ncpd.lua), and the suspect's own
 * warning. Drawn on the notice layer: it takes neither the keyboard nor the
 * pointer, so a player in a fight keeps fighting while it is up.
 *
 * TWO STAGES. The FLASH -- a strobing red frame, a hazard-striped panel, the
 * title between two glyphs, a subtitle, the lines and a draining clock -- runs
 * for `flashMs` and plays `sound` once. Then the STRIP: one line at the top of
 * the screen with the title and the brief, its own clock draining the rest of
 * `durationMs`. A second alarm inside `quietMs` of the last flash goes straight
 * to the strip, so a busy night does not strobe the squad's screens every few
 * seconds.
 *
 * Everything on it is text from Lua (`text`, never markup), and every number is
 * held to a range: a payload cannot keep the screen up past a minute, or hold
 * the flash back for longer than the alarm itself lasts.
 */

const shown = ref(false)
const flashing = ref(false)
const title = ref('')
const subtitle = ref('')
const lines = ref<string[]>([])
const brief = ref<string[]>([])
// Bumped per alarm, so a new one re-keys the strip and its clock starts again.
const round = ref(0)
const duration = ref(0)
// False for the first frame of an alarm, so the clock is drawn full and then
// drains over `duration` (a transition needs a frame to start from).
const draining = ref(false)

let hideTimer: ReturnType<typeof setTimeout> | undefined
let drainTimer: ReturnType<typeof setTimeout> | undefined
let flashTimer: ReturnType<typeof setTimeout> | undefined
let lastFlash = 0

function clearTimers(): void {
  if (hideTimer !== undefined) clearTimeout(hideTimer)
  if (drainTimer !== undefined) clearTimeout(drainTimer)
  if (flashTimer !== undefined) clearTimeout(flashTimer)
  hideTimer = undefined
  drainTimer = undefined
  flashTimer = undefined
}

function clamp(value: number, low: number, high: number): number {
  return Math.min(high, Math.max(low, value))
}

useBridge('opx:alarm:show', (payload: Payload) => {
  clearTimers()
  title.value = text(payload.title, 'MAXTAC ALERT')
  subtitle.value = text(payload.subtitle)
  lines.value = list(payload.lines).map((line) => text(line)).filter((line) => line !== '')
  const given = list(payload.brief).map((line) => text(line)).filter((line) => line !== '')
  // Without a brief, the strip says the lines but the last (the call to respond).
  brief.value = given.length > 0 ? given : lines.value.slice(0, Math.max(1, lines.value.length - 1))
  duration.value = clamp(num(payload.durationMs, 9000), 1000, 60000)
  const flashMs = clamp(num(payload.flashMs, 1500), 0, duration.value)
  const quietMs = clamp(num(payload.quietMs, 30000), 0, 600000)
  const now = Date.now()
  const quiet = lastFlash !== 0 && now - lastFlash < quietMs
  flashing.value = !quiet && flashMs > 0
  if (flashing.value) {
    lastFlash = now
    flashTimer = setTimeout(() => {
      flashing.value = false
    }, flashMs)
  }
  draining.value = false
  round.value += 1
  shown.value = true
  drainTimer = setTimeout(() => {
    draining.value = true
  }, 32)
  hideTimer = setTimeout(() => {
    shown.value = false
    flashing.value = false
  }, duration.value)
  // The sound goes with the flash: a quiet alarm is a quiet one.
  const sound = text(payload.sound)
  if (flashing.value && sound !== '') void playClip(sound, clamp(num(payload.volume, 1), 0, 1))
})

useBridge('opx:alarm:hide', () => {
  clearTimers()
  shown.value = false
  flashing.value = false
})

onUnmounted(clearTimers)
</script>

<template>
  <Transition name="alarm">
    <div v-if="shown" class="alarm" role="alert" aria-live="assertive">
      <Transition name="frame">
        <div v-if="flashing" class="frame" />
      </Transition>
      <Transition name="swap" mode="out-in" type="transition">
        <section v-if="flashing" key="flash" class="flash">
          <div class="hazard" />
          <div class="content">
            <p class="title">
              <span class="glyph">▲</span>
              <span class="word">{{ title }}</span>
              <span class="glyph">▲</span>
            </p>
            <p v-if="subtitle" class="subtitle">{{ subtitle }}</p>
            <ul v-if="lines.length" class="lines">
              <li v-for="(line, index) in lines" :key="index">{{ line }}</li>
            </ul>
            <span class="clock">
              <span
                class="drain"
                :style="{ transform: draining ? 'scaleX(0)' : 'scaleX(1)', transitionDuration: `${duration}ms` }"
              />
            </span>
          </div>
          <div class="hazard hazard-reverse" />
        </section>
        <section v-else :key="`strip-${round}`" class="strip">
          <span class="strip-glyph">▲</span>
          <span class="strip-title">{{ title }}</span>
          <span v-for="(line, index) in brief" :key="index" class="strip-line">{{ line }}</span>
          <span class="clock strip-clock">
            <span
              class="drain"
              :style="{ transform: draining ? 'scaleX(0)' : 'scaleX(1)', transitionDuration: `${duration}ms` }"
            />
          </span>
        </section>
      </Transition>
    </div>
  </Transition>
</template>

<style scoped>
.alarm { position: absolute; inset: 0; pointer-events: none; overflow: hidden; }

/* The screen's edge, strobing red while the flash is up. */
.frame {
  position: absolute;
  inset: 0;
  box-shadow: inset 0 0 0 6px var(--op-red), inset 0 0 28px 6px rgba(var(--op-red-rgb), 0.45);
  animation: alarm-strobe 0.25s steps(2, jump-none) infinite;
}

.flash {
  position: absolute;
  top: 7%;
  left: 50%;
  transform: translateX(-50%);
  width: min(1100px, 88vw);
  display: flex;
  flex-direction: column;
  background: rgba(8, 3, 5, 0.8);
  box-shadow: 0 0 40px rgba(var(--op-red-rgb), 0.4);
  animation: alarm-panel-in 0.22s cubic-bezier(0.2, 0.9, 0.25, 1.15) both;
  transform-origin: top center;
}

.hazard {
  height: 10px;
  background: repeating-linear-gradient(-45deg, var(--op-red) 0 14px, rgba(10, 4, 6, 0.95) 14px 28px);
  background-size: 40px 10px;
  animation: alarm-hazard 0.9s linear infinite;
}

.hazard-reverse { animation-direction: reverse; }

.content {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  padding: 14px var(--op-inset-x) 12px;
}

.title {
  margin: 0;
  display: flex;
  align-items: center;
  gap: 20px;
  font-family: var(--op-font-display);
  font-weight: 700;
  font-size: 68px;
  line-height: 1;
  letter-spacing: 0.14em;
  color: var(--op-red-hi);
  text-shadow: 0 0 14px rgba(var(--op-red-rgb), 0.9), 0 0 32px rgba(var(--op-red-rgb), 0.55);
  text-transform: uppercase;
}

.word { animation: alarm-word 0.5s steps(2, jump-none) 3; }

.glyph {
  font-size: 40px;
  color: var(--op-red);
  animation: alarm-blink 0.6s steps(2, jump-none) infinite;
}

.subtitle {
  margin: 0;
  font-family: var(--op-font-display);
  font-weight: 600;
  font-size: 28px;
  letter-spacing: 0.2em;
  color: var(--op-text);
  text-transform: uppercase;
}

.lines {
  margin: 2px 0 0;
  padding: 0;
  list-style: none;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 2px;
  font-family: var(--op-font-mono);
  font-size: 18px;
  color: var(--op-red-text);
}

/* The last line is the call to respond. */
.lines li:last-child {
  color: var(--op-text);
  font-weight: 600;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

/* After the flash: one line at the top of the screen for the rest of the alarm. */
.strip {
  position: absolute;
  top: 12px;
  left: 50%;
  transform: translateX(-50%);
  max-width: min(1100px, 92vw);
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 7px 18px 11px;
  background: rgba(8, 3, 5, 0.78);
  border: 1px solid rgba(var(--op-red-rgb), 0.75);
  box-shadow: 0 0 18px rgba(var(--op-red-rgb), 0.35);
  white-space: nowrap;
  overflow: hidden;
  animation: alarm-strip-pulse 0.6s ease-out 2;
}

.strip-glyph {
  font-size: 18px;
  color: var(--op-red);
  animation: alarm-blink 0.6s steps(2, jump-none) infinite;
}

.strip-title {
  font-family: var(--op-font-display);
  font-weight: 700;
  font-size: 24px;
  letter-spacing: 0.14em;
  color: var(--op-red-hi);
  text-transform: uppercase;
}

.strip-line {
  font-family: var(--op-font-mono);
  font-size: 16px;
  color: var(--op-text);
  overflow: hidden;
  text-overflow: ellipsis;
}

.strip-line::before { content: "·"; margin-right: 14px; color: var(--op-red); }

/* What is left of the alarm, as a bar that drains. */
.clock {
  display: block;
  width: min(560px, 50vw);
  height: 3px;
  margin-top: 6px;
  background: rgba(var(--op-red-rgb), 0.18);
}

.strip-clock { position: absolute; left: 0; right: 0; bottom: 0; width: auto; margin: 0; }

.drain {
  display: block;
  width: 100%;
  height: 100%;
  background: var(--op-red);
  transform-origin: left center;
  transition-property: transform;
  transition-timing-function: linear;
}

.alarm-enter-active { transition: opacity 0.12s ease-out; }
.alarm-leave-active { transition: opacity 0.5s ease-in; }
.alarm-enter-from, .alarm-leave-to { opacity: 0; }
.frame-leave-active { transition: opacity 0.3s ease-in; }
.frame-leave-to { opacity: 0; }
.swap-enter-active, .swap-leave-active { transition: opacity 0.15s ease; }
.swap-enter-from, .swap-leave-to { opacity: 0; }

@keyframes alarm-strobe { from { opacity: 1; } to { opacity: 0.2; } }
@keyframes alarm-panel-in { from { transform: translateX(-50%) scaleY(0); } to { transform: translateX(-50%) scaleY(1); } }
@keyframes alarm-strip-pulse {
  0% { box-shadow: 0 0 0 rgba(var(--op-red-rgb), 0); border-color: var(--op-red-hi); }
  50% { box-shadow: 0 0 26px rgba(var(--op-red-rgb), 0.7); }
  100% { box-shadow: 0 0 18px rgba(var(--op-red-rgb), 0.35); }
}
@keyframes alarm-hazard { from { background-position: 0 0; } to { background-position: 40px 0; } }
@keyframes alarm-word { from { opacity: 1; } to { opacity: 0.35; } }
@keyframes alarm-blink { from { opacity: 1; } to { opacity: 0; } }
</style>
