<script setup lang="ts">
import { computed, onUnmounted, ref, shallowRef } from 'vue'
import { list, num, table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'
import { imageFromFile, monogram } from './format'
import { corners } from '@/stores/corners'

/**
 * THE HOTBAR PEEK -- what is in slots one to five, for a few seconds.
 *
 * WHY IT EXISTS. The hotbar keys work with the bag shut, which is the point of
 * them and also the problem: nothing on screen says what they are bound to until
 * you open the bag and look, by which time you did not need the key.
 *
 * IT TIMES ITSELF, and that is the same bargain the toast makes. Lua sends
 * `holdMs` once and says nothing more; a `setTimeout` here takes the row down.
 * A version that was told to hide would be a Lua timer ticking on every client
 * for the sake of a thing that is on screen for four seconds at a time.
 *
 * IT HOLDS NO CATALOGUE. The grid resolves a picture out of the catalogue it was
 * sent; this layer has none, so Lua resolves the five rows and sends the label,
 * the count and the catalogue's own file name with them. `imageFromFile` is the
 * one place the `images/` base lives, shared with the grid.
 *
 * IT TAKES NO POINTER AND NO KEYBOARD. It is on the overlay layer, which is
 * `pointer-events: none` for the whole layer, and nothing here re-enables it.
 * A row the player could click would be a second, worse way to use an item.
 *
 * -- DESIGN PASS 02 -----------------------------------------------------------
 *
 * IT IS THE INVENTORY CELL, SHRUNK AND LAID IN A ROW. Same chamfered frame, same
 * keycap in the corner, same monogram behind a picture that will not load --
 * because it is the same object, and a second vocabulary for "a slot with a
 * thing in it" would make the peek teach the player something the bag then
 * contradicts.
 */
const { t } = useLocale()

interface Row {
  slot: number
  key: string
  name: string
  label: string
  image: string
  count: number
}

const rows = shallowRef<Row[]>([])
const open = ref(false)

/** Names whose picture 404'd. Kept so the monogram does not flicker back. */
const broken = ref<Record<string, true>>({})

let fall: ReturnType<typeof setTimeout> | undefined

function clearFall(): void {
  if (fall !== undefined) clearTimeout(fall)
  fall = undefined
}

useBridge('opx:inventory:slotbar', (payload: Payload) => {
  clearFall()

  const incoming = list(payload.slots).map((entry): Row => {
    const row = table(entry)
    return {
      slot: num(row.slot),
      key: text(row.key),
      name: text(row.name),
      label: text(row.label),
      image: text(row.image),
      count: num(row.count),
    }
  })

  const holdMs = Math.max(0, num(payload.holdMs))
  // AN EMPTY ROW OR NO TIME LEFT IS "TAKE IT DOWN". Lua uses the same channel to
  // hide as to show, so a bag opening over the peek is one message and not a
  // second channel that could arrive out of order with the first.
  if (incoming.length === 0 || holdMs <= 0) {
    open.value = false
    rows.value = []
    return
  }

  rows.value = incoming
  open.value = true
  fall = setTimeout(() => { open.value = false }, holdMs)
})

onUnmounted(clearFall)

function onBroken(name: string): void {
  broken.value = { ...broken.value, [name]: true }
}

const cells = computed(() =>
  rows.value.map((row) => ({
    ...row,
    filled: row.name !== '',
    art: row.name !== '' && !broken.value[row.name]
      ? imageFromFile(row.name, row.image)
      : '',
    mark: monogram(row.label || row.name),
  })))
</script>

<template>
  <!-- ABOVE THE DIAL WHILE DRIVING. Both sit on the bottom centre, and the dial
       publishes how high it reaches (`stores/corners.ts`); the peek stands on that
       rather than over it, and comes back to its own inset when the car is left. -->
  <div
    v-if="open"
    class="slotbar"
    :style="corners.bottomCenter > 0 ? { bottom: `max(var(--op-inset-y), ${corners.bottomCenter}px)` } : undefined"
  >
    <span
      v-for="cell in cells"
      :key="cell.slot"
      class="cell op-frame"
      data-augmented-ui="tr-clip border"
    >
      <span v-if="cell.key" class="cap">{{ cell.key }}</span>

      <img
        v-if="cell.art"
        class="art"
        :src="cell.art"
        alt=""
        draggable="false"
        @error="onBroken(cell.name)"
      />
      <span v-else-if="cell.filled" class="mark op-truncate">{{ cell.mark }}</span>
      <span v-else class="mark faint op-truncate">{{ t('inventory.slotbar.empty') }}</span>

      <span v-if="cell.count > 1" class="count">{{ cell.count }}</span>
    </span>
  </div>
</template>

<style scoped>
/* =============================================================================
   The inventory cell, shrunk and laid in a row. It borrows the grid's frame, its
   keycap and its monogram fallback rather than inventing a smaller vocabulary:
   the peek is a preview of the bag, and a preview that looks like something else
   teaches the wrong thing.
   ========================================================================== */

.slotbar {
  position: absolute;
  left: 50%;
  bottom: var(--op-inset-y);
  transform: translateX(-50%);
  display: flex;
  gap: var(--op-space-1);
  /* Inherited from the layer and said again: the row is a label, not a control.
     A cell the player could click would be a second way to use an item. */
  pointer-events: none;
}

/* THE SAME CELL AS THE BAG, at three quarters of it. It borrowed the grid's
   frame in spirit and not in its values: two chamfers where the bag has one, a
   solid border where the bag's is 70% alpha, and `--op-plane-bg` where the bag
   sits on `--op-plate`. Side by side they read as two different components, and
   the peek's whole job is to be a preview of the bag. The tokens are the
   grid cell's now, verbatim -- 72px against the grid's 90, which is the "a
   little larger" the owner asked for without becoming a second inventory
   screen across the bottom of the display. */
.cell {
  position: relative;
  box-sizing: border-box;
  width: 72px;
  height: 72px;
  display: grid;
  place-items: center;
  padding: var(--op-space-1);

  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: rgba(var(--op-red-idle-rgb), 0.70);
  background: var(--op-plate);
}

/* AN EMPTY SLOT IS DRAWN THE SAME AS A FULL ONE. It used to take a fainter
   border, which made the row a diagram of what you are carrying rather than a
   reminder of what the keys are bound to -- and the owner's answer to being
   shown which cell matters was that it does not. The cell is still drawn, and
   still says "empty" inside it: closing the gap would renumber the row the
   player is trying to memorise, which is the one thing this row exists to
   prevent. */

.art {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
}

/* `.op-truncate` in the template does the cut; this is the width it cuts TO. A
   grid item under `place-items: center` is sized by its content, so `overflow:
   hidden` on its own clips nothing -- a long mark simply drew past the cell.
   `max-width` is what gives the ellipsis an edge to land on. */
.mark {
  max-width: 100%;
  font-size: 15px;
  letter-spacing: 0.06em;
  color: var(--op-red-text);
}

.mark.faint {
  font-size: 10px;
  text-transform: uppercase;
  color: var(--op-text-faint);
}

/* The keycap, in the frame's own colour, exactly as the grid draws it. */
.cap {
  position: absolute;
  top: 2px;
  left: 4px;
  font-family: var(--op-font-mono, monospace);
  font-size: 11px;
  line-height: 1;
  color: var(--op-red-text);
}

.count {
  position: absolute;
  right: 4px;
  bottom: 2px;
  font-family: var(--op-font-mono, monospace);
  font-size: 12px;
  line-height: 1;
  color: var(--op-text);
}
</style>
