<script setup lang="ts">
import { onUnmounted, ref, shallowRef } from 'vue'
import { bool, num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE TIMED-ACTION BAR -- what the player is doing, and how much of it is left.
 *
 * IT ANIMATES ITSELF OFF A DEADLINE, and that is the whole of why it is smooth.
 * Lua sends `durationMs` ONCE, at the start, and then says nothing until the bar
 * comes down: the fill is a CSS transition from empty to full over exactly that
 * long, so the browser interpolates it on the compositor and a Lua pass every
 * 100ms costs the bar nothing. A version that sent a percentage per pass would
 * move in ten visible steps a second and would put a page write on the wire for
 * every one of them.
 *
 * NOTHING HERE DECIDES ANYTHING. It does not know what the action is, whether it
 * finished, or what happens next; it draws what it is told, including the key
 * that cancels a bar that said it may be cancelled. It emits nothing: the cancel
 * is a key mapping in Lua, because this layer never holds the keyboard.
 *
 * IT TAKES NO POINTER AND NO KEYBOARD. It is on the overlay layer, which is
 * `pointer-events: none` for the whole layer, and this file does not re-enable
 * it. A bar that captured the keyboard would stop the player moving -- and the
 * holding is `Open77.input`'s job, done in Lua, exactly as `ui-kit` says.
 *
 * -- DESIGN PASS 02 -----------------------------------------------------------
 *
 * IT IS THE VITALS GAUGE, LYING DOWN. Same chamfered 1px frame, same single
 * filled bar inside it, same `scaleX` from the left, same cut corner on the bar
 * itself -- because it is the same object answering the same kind of question,
 * and a second bar shape would be a second vocabulary for "how much of this is
 * left". What it adds is a label above it, since a gauge is read against a row
 * it sits in and this one arrives alone in the middle of the screen.
 *
 * BOTTOM CENTRE, ABOVE THE VEHICLE CHIP'S LANE. It is the one surface that
 * appears unbidden and must be read immediately, so it goes where the eye
 * already is -- and it is the only thing on that lane while it is up, because a
 * timed action and a speed dial do not happen at once.
 */
const { t } = useLocale()

const open = ref(false)
const label = ref('')
const cancelable = ref(false)
/** The key the player has bound to cancel, as Lua named it. */
const cancelKey = ref('')

/** 0 while empty, 1 once the transition has been started. Held in a ref rather
    than written straight onto the element so the browser gets one frame at zero
    before the transition begins -- set in the same frame, it would jump. */
const filled = ref(false)

/** One per `show`, and the bar's key. A show arriving while a bar is still up -- one
    action straight after another -- used to keep the element: its "empty" was a
    transition back from wherever the last bar stood, reversed 32ms later, so the
    new bar started at (nearly) full and stayed there. A new key is a new element,
    and a new element starts at zero. */
const run = ref(0)

/** The transition's own duration, in milliseconds. */
const span = shallowRef(0)

let raise: ReturnType<typeof setTimeout> | undefined

function clearRaise(): void {
  if (raise !== undefined) clearTimeout(raise)
  raise = undefined
}

useBridge('opx:progress:show', (payload: Payload) => {
  clearRaise()
  // The key; translated where it is drawn, so a catalogue landing late still applies.
  label.value = text(payload.label)
  cancelKey.value = text(payload.cancelKey)
  cancelable.value = bool(payload.cancelable) && cancelKey.value !== ''
  span.value = Math.max(0, num(payload.durationMs))
  filled.value = false
  run.value += 1
  open.value = true
  // ONE FRAME AT ZERO. A transition started in the frame the element mounts in
  // has no "from" to interpolate out of, so the bar snaps full and then sits
  // there. The timeout is the frame.
  raise = setTimeout(() => { filled.value = true }, 32)
})

useBridge('opx:progress:hide', () => {
  clearRaise()
  open.value = false
  filled.value = false
})

onUnmounted(clearRaise)
</script>

<template>
  <div v-if="open" class="progress">
    <section class="plate op-plane op-ink">
      <p class="label op-eyebrow op-truncate">{{ t(label) }}</p>

      <span class="track op-frame" data-augmented-ui="tr-clip border">
        <span
          :key="run"
          class="bar"
          :style="{
            transform: filled ? 'scaleX(1)' : 'scaleX(0)',
            transitionDuration: `${span}ms`
          }"
        />
      </span>

      <p v-if="cancelable" class="hint op-eyebrow">{{ t('progress.cancel', { key: cancelKey }) }}</p>
    </section>
  </div>
</template>

<style scoped>
/* =============================================================================
   The vitals gauge, lying down and alone. It borrows that block's frame, its
   single fill and its `scaleX` rather than inventing a bar of its own: they
   answer the same question and one shape should say it.
   ========================================================================== */

.progress {
  position: absolute;
  left: 50%;
  bottom: calc(var(--op-inset-y) + 96px);
  transform: translateX(-50%);
  /* Inherited from the layer, and said again here: this is the one thing on the
     overlay that appears over whatever the player is aiming at. */
  pointer-events: none;
}

.plate {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: var(--op-space-1);
  width: 280px;
}

/* `.op-truncate` in the template keeps it to one line; `max-width` is what it
   cuts to. The plate is a fixed 280px column, so a long caption used to wrap and
   push the bar down the screen mid-action -- the one element on this surface that
   must not move while it is being watched. The hint under the bar is NOT cut: it
   is a fixed instruction telling the player which key stops this, and half an
   instruction is worse than two lines of one. */
.label {
  margin: 0;
  max-width: 100%;
  color: var(--op-red-text);
  text-transform: uppercase;
}

/* The frame: the gauge's own, at the gauge's own height. */
.track {
  box-sizing: border-box;
  width: 100%;
  height: 10px;
  padding: 2px;

  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: var(--op-red-idle);
}

/* THE ONE FILLED SHAPE, and it is data. `scaleX` from the left, never `width`:
   a width is layout and this moves for seconds at a time. The cut corner is the
   vitals bar's, so the two read as one object seen twice. */
.bar {
  display: block;
  width: 100%;
  height: 100%;
  background: var(--op-red);
  clip-path: polygon(0 0, calc(100% - 4px) 0, 100% 4px, 100% 100%, 0 100%);
  transform-origin: left center;
  transform: scaleX(0);
  /* LINEAR, and the duration comes from the payload. An eased bar lies about
     how much time is left, which is the only thing it is for. */
  transition-property: transform;
  transition-timing-function: linear;
}

.hint {
  margin: 0;
  color: var(--op-text-faint);
}
</style>
