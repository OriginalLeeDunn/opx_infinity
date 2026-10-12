<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { emit } from '@/bridge/channel'
import { bool, num, table, text, own } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { CLEARANCE, RESTING_BOTTOM, inputDrop, inputHeight, inputOpen } from './state'

/**
 * THE CHAT LOG -- the overlay half of the box.
 *
 * Draws what was said and nothing else: it never takes a pointer, never takes the
 * keyboard, and has no way to send anything but its own `ready`. The input line is
 * `ChatInput.vue` on the modal layer.
 *
 * FADING IS A READ, NOT A TIMER PER LINE. Every line carries the moment it landed
 * and the template asks whether it is still young enough; one interval ticks a
 * clock while anything is still fading and stops when nothing is. Sixty lines with
 * sixty `setTimeout`s was the shape this replaced, and it leaked one per line
 * whenever the log was cleared.
 *
 * A line keeps its own kind. No colour ever travels on the wire: Lua sends
 * `kind: 'error'` and the tokens below decide what that looks like, so a palette
 * change does not have to chase values frozen into Lua months ago.
 */

interface Line {
  /** Monotonic within this page. Vue needs a stable key and Lua sends none. */
  id: number
  kind: string
  author: string
  text: string
  /** When it landed, for the fade. */
  at: number
}

const ANCHORS: Record<string, string> = {
  'bottom-left': 'anchor-bottom-left',
  'bottom-center': 'anchor-bottom-center',
  'top-left': 'anchor-top-left',
  'top-center': 'anchor-top-center'
}

const lines = ref<Line[]>([])
const visible = ref(true)
const anchor = ref('anchor-bottom-left')
const offset = ref(155)
const width = ref(620)
const history = ref(60)
const fadeMs = ref(12000)

const now = ref(Date.now())
let ticker: ReturnType<typeof setInterval> | null = null
let sequence = 0

/**
 * THE ROOM THE STYLESHEET ALREADY LEAVES FOR THE INPUT LINE, in pixels: one
 * field row at the top anchors (`--op-space-7`), and the distance the input
 * hangs below the log's own edge at the bottom ones (`RESTING_BOTTOM` in
 * `state.ts`, `--op-space-6`).
 *
 * Written as numbers because what is computed from them is compared against a
 * height measured in pixels on the other layer; they are the same two tokens the
 * anchor rules below use, and moving one means moving the other.
 */
const RESTING_TOP = 48

const atTop = computed(
  () => anchor.value === 'anchor-top-left' || anchor.value === 'anchor-top-center'
)

/**
 * HOW FAR THE LOG STEPS OUT OF THE INPUT LINE'S WAY while the box is open.
 *
 * The clearance in the stylesheet is one field row, which was right until the
 * completion list existed: that list is up to eight rows tall, it appears and
 * grows as the player types, and it drew straight over the log -- so pressing the
 * key to talk hid everything that had just been said.
 *
 * The input line measures itself and publishes its height, and this is whatever
 * that height overruns the resting clearance by. Zero while the box is closed,
 * and zero while the block still fits, so nothing moves in the common case.
 */
const lift = computed(() => {
  if (!inputOpen.value) return 0
  // At a bottom anchor the input has already dropped clear of the log by the field
  // row's overrun (`inputDrop`), so the room is that much larger and an open box
  // with nothing typed leaves the log exactly where it rested (#120).
  const resting = atTop.value ? RESTING_TOP : RESTING_BOTTOM + inputDrop.value
  return Math.max(0, inputHeight.value + CLEARANCE - resting)
})

/** A line is drawn while the box is open, when fading is off, or while it is young. */
function alive(line: Line): boolean {
  if (inputOpen.value || fadeMs.value <= 0) return true
  return now.value - line.at < fadeMs.value
}

const shown = computed(() => lines.value.filter(alive))

/**
 * Runs the clock only while something can still fade out of view. An always-on
 * interval on the overlay costs a wake-up every half second for the whole session,
 * and the overlay is the one surface that is always drawn.
 */
function syncTicker(): void {
  // Only while the NEWEST line is still young. `lines.length > 0` kept the interval
  // alive for the whole session once anything had been said -- the history outlives
  // the fade -- re-rendering the log twice a second with nothing left to hide. Each
  // tick re-checks, so the clock stops itself on the tick that hides the last line.
  const newest = lines.value[lines.value.length - 1]
  const wanted = fadeMs.value > 0 && !inputOpen.value && newest !== undefined
    && Date.now() - newest.at < fadeMs.value
  if (wanted && ticker === null) {
    ticker = setInterval(() => {
      now.value = Date.now()
      syncTicker()
    }, 500)
  } else if (!wanted && ticker !== null) {
    clearInterval(ticker)
    ticker = null
  }
}

function push(payload: Payload): void {
  const line = table(payload.line)
  const body = text(line.text)
  if (body === '') return

  sequence += 1
  lines.value.push({
    id: sequence,
    kind: text(line.kind, 'say'),
    author: text(line.author),
    text: body,
    at: Date.now()
  })

  // Older lines fall off the top. Done here rather than in the template so the
  // array cannot grow for a session on a server that talks a lot.
  const cap = Math.max(1, history.value)
  if (lines.value.length > cap) lines.value.splice(0, lines.value.length - cap)
  now.value = Date.now()
  syncTicker()
}

useBridge('opx:chat:view', (payload: Payload) => {
  // Every payload names its layer, and the input line's are not ours.
  if (text(payload.surface) !== 'overlay') return

  switch (text(payload.kind)) {
    case 'config': {
      anchor.value = own(ANCHORS, text(payload.anchor)) ?? 'anchor-bottom-left'
      offset.value = num(payload.offset, 155)
      width.value = num(payload.width, 620)
      history.value = num(payload.history, 60)
      fadeMs.value = num(payload.fadeMs, 12000)
      visible.value = bool(payload.visible, true)
      syncTicker()
      break
    }
    case 'line':
      push(payload)
      break
    case 'clear':
      lines.value = []
      syncTicker()
      break
    case 'visible':
      visible.value = bool(payload.visible, true)
      break
  }
})

/* Closing the box restarts the clock. The ticker is off while the box is open, so
   `now` froze at the open; lines said while it was open (the first chat of a
   session, or after a clear, started no clock at all) then never faded until the
   next line arrived. */
watch(inputOpen, () => {
  now.value = Date.now()
  syncTicker()
})

onMounted(() => {
  // The signal Lua waits for. Nothing is published to a layer that has not said
  // this, so a log that never reported ready is a log that stays empty for ever.
  emit('opx:chat:ready', { surface: 'overlay' })
})

onUnmounted(() => {
  if (ticker !== null) clearInterval(ticker)
  ticker = null
})
</script>

<template>
  <div
    v-if="visible && shown.length > 0"
    class="chat-log"
    :class="anchor"
    :style="{
      '--chat-offset': `${offset}px`,
      '--chat-width': `${width}px`,
      '--chat-lift': `${lift}px`
    }"
  >
    <p v-for="line in shown" :key="line.id" class="chat-line" :class="`is-${line.kind}`">
      <span v-if="line.author" class="chat-author">{{ line.author }}</span>
      <span class="chat-text">{{ line.text }}</span>
    </p>
  </div>
</template>

<style scoped>
/* =============================================================================
   DESIGN PASS 02 -- RED, OUTLINED, TILTED. The chat log's half of it.

   This block draws on the overlay, so it takes the HUD's half of the pass
   rather than the menu's, and for the HUD's reason: IT HAS NO BACKING. Every
   line sits on live gameplay, which is why the two-pass black ink is declared
   once here and inherited by every line under it, and why there is no veil, no
   fill and no `backdrop-filter` -- the first version of this file had all three
   and read as a window pasted over the game.

   THE ERROR LINE IS NOT RED. Rule 4 of the contract: red is the voice of this
   surface, so it cannot also be its alarm. A red refusal among red author tags
   says nothing, so a refusal goes WHITE-HOT (`--alarm`) and changes family
   rather than shade. `--op77-danger` is not used here, exactly as it is not
   used anywhere in the HUD folder.

   NO FRAME. The log is a column of text and not a cluster: the HUD's clusters
   that carry a `border-image` are the ones with something to enclose. What
   marks this one is a single lit arete down the leading edge -- the same
   1px red rule a menu row uses at rest -- and nothing else.
   ========================================================================== */

.chat-log {
  position: absolute;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  width: var(--chat-width);
  max-width: calc(100vw - var(--op-inset-x) * 2);
  padding: var(--op-space-1) 0 var(--op-space-1) var(--op-space-3);
  pointer-events: none;

  /* NEVER TALLER THAN THE ROOM ITS ANCHOR LEAVES, and the overflow is the OLDEST
     lines. Sixty lines at 14px is ~1100px; with the box open every one of them is
     drawn, and at a top anchor the log grows down -- so the newest lines, the ones
     the player opened the chat to read, were the ones below the bottom of the
     screen. `flex-end` puts the overflow at the top, where the old lines are; each
     anchor below sets the height it actually has. */
  justify-content: flex-end;
  overflow: hidden;

  /* The leading edge, and the only mark this block carries. */
  border-left: 1px solid var(--op-red-idle);

  /* THE GROUND. The header above says this block has no backing because it sits
     on live gameplay -- that was the pass's rule and the game overruled it: a
     line of chat crossing a lit billboard was unreadable whatever the ink shadow
     did, and the owner asked for a background on everything carrying text.

     Quiet rather than full strength, and for the reason the token gives: this is
     up to sixty lines tall while the box is open, which is a quarter of the
     screen, and a quarter of the screen at 0.78 is a window pasted over the game
     -- the exact thing the veil and the `backdrop-filter` were removed to avoid.
     The right-hand padding is new: a plate needs room past the last glyph or it
     reads as a highlighter rather than a ground. */
  padding-right: var(--op-space-3);
  background: var(--op-plate-quiet);

  /* LIGHTER THAN `--op-ink`, and deliberately: the house pair is tuned for a
     glyph sitting on nothing, and this column sits on a plate AND runs to sixty
     lines. The full pair over that much backed text greys the whole block --
     what lifts one unbacked readout off a plaza smothers a paragraph. Declared
     once here and inherited by every line. */
  text-shadow:
    0 1px 0 rgba(0, 0, 0, 0.92),
    0 0 6px rgba(0, 0, 0, 0.65);

  /* The lift, eased. See the anchor rules. */
  transition:
    top 90ms ease-out,
    bottom 90ms ease-out;
}

/* EVERY ANCHOR CARRIES `--chat-lift`, which is 0 unless the input block below (or
   above) it has grown past the room these rules leave. See `lift` in the script:
   the completion list is what made a fixed clearance wrong. The move is eased
   because the list grows a row at a time as the player types, and a column of
   text snapping by 30px per keystroke is harder to read than one that slides. */
.anchor-bottom-left {
  left: var(--op-inset-x);
  bottom: calc(var(--chat-offset) + var(--chat-lift, 0px));
  max-height: calc(100vh - var(--chat-offset) - var(--chat-lift, 0px) - var(--op-inset-y));
}

/* Centred on the screen's axis, clear of the vitals in the corner. The width is
   the operator's, so the shift is half of it and not a fixed number. The leading
   rule moves with it and stays the block's left edge. */
.anchor-bottom-center {
  left: 50%;
  transform: translateX(-50%);
  bottom: calc(var(--chat-offset) + var(--chat-lift, 0px));
  max-height: calc(100vh - var(--chat-offset) - var(--chat-lift, 0px) - var(--op-inset-y));
}

/* TOP ANCHORS PUT THE LOG UNDER THE INPUT LINE, which is the mirror of the
   bottom ones. `ChatInput.vue` sits on the offset itself and this clears its row
   -- one line of text plus its frame -- plus `--chat-lift` for whatever the
   completion list adds to it, so the two never overlap.

   Top of the screen, on its axis, is chosen because nothing of the HUD lives
   there: the bottom-left corner is the vitals and the status chips, and a log
   pinned down there sits on the numbers the player is reading. */
.anchor-top-left {
  left: var(--op-inset-x);
  top: calc(var(--chat-offset) + var(--op-space-7) + var(--chat-lift, 0px));
  max-height: calc(100vh - var(--chat-offset) - var(--op-space-7) - var(--chat-lift, 0px) - var(--op-inset-y));
}

.anchor-top-center {
  left: 50%;
  transform: translateX(-50%);
  top: calc(var(--chat-offset) + var(--op-space-7) + var(--chat-lift, 0px));
  max-height: calc(100vh - var(--chat-offset) - var(--op-space-7) - var(--chat-lift, 0px) - var(--op-inset-y));
}

.chat-line {
  margin: 0;
  font-family: var(--op-font-body);
  font-size: var(--op-fs-body);
  line-height: 1.35;
  color: var(--op-red-text);
  overflow-wrap: anywhere;
}

.chat-author {
  margin-right: var(--op-space-2);
  font-family: var(--op-font-mono);
  font-size: var(--op-fs-label);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: var(--op-red);
}

/* White-hot, and heavier with it: an alarm has to be readable without being
   looked at, and weight is the second channel after luminance. */
.is-error .chat-author,
.is-error .chat-text {
  color: var(--op-alarm);
}

.is-error .chat-author {
  font-weight: 600;
}

.is-warning .chat-author {
  color: var(--op-red-hi);
}

/* A line the runtime wrote about itself, rather than one a player said. It
   steps back out of the red entirely: this surface's voice is for voices. */
.is-system .chat-author,
.is-info .chat-author {
  color: var(--op-text-dim);
}
</style>
