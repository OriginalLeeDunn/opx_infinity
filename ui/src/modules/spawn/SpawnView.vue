<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useLocale } from '@/composables/useLocale'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { text, records } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'

// The eyebrow from the catalogue, so a French player does not read `SPAWN`; the
// English word only before the catalogue has reached the page.
const { t, has } = useLocale()
const eyebrow = computed(() => (has('spawn.eyebrow') ? t('spawn.eyebrow') : 'SPAWN'))

/**
 * THE SPAWN MENU -- where a character starts.
 *
 * Offered on a world enter the operator's policy says to ask about. Lua opens it with
 * the places to draw and a duration, and the page answers with the ID of one of them;
 * the place itself is the server's to look up, so nothing here can move anybody
 * anywhere the server has not already agreed to. Picking nothing is a real answer --
 * the server places the body where the character's own row already says -- which is
 * why nothing here insists on one.
 *
 * ONE PRESS IS THE CHOICE. Clicking a card sends it -- you do not select and then
 * confirm, because "spawn me at the coast" is one intent and asking for it twice is
 * a menu pretending the first click did not count. The arrow keys plus Enter take the
 * same route, so the two input paths cannot drift apart.
 *
 * SO THERE IS NO CONFIRM CONTROL, and there was one. It sat under the grid and did
 * exactly what a click already did: a second control for an intent the first press
 * had already sent. It read as a step -- pick, then press SPAWN -- which is the one
 * thing the whole surface is built not to be, and a player who had clicked a card and
 * then looked at a lit button reasonably wondered whether the click had counted. It
 * existed for the keyboard; Enter goes straight to `confirm()` instead.
 *
 * AND NO CLOCK. The page used to draw the window counting down beside the title. It
 * was display only -- it reached zero and did nothing, because the server counts the
 * same window against its own clock and only that count ends the choice -- so all it
 * ever did was put a deadline in front of somebody making a one-press decision. The
 * duration is not sent to this page any more; running out is still handled, on
 * `spawn:close` with `reason = 'timeout'`, which is where it always was.
 *
 * THE MENU DOES NOT CLOSE ON THAT PRESS. It closes when Lua says so -- `spawn:close`,
 * carrying what actually happened -- for the same reason a panel does not select its
 * own item: a page that closed itself would show the player a spawn the server
 * refused, and there is no second chance at this one. The one thing this page decides
 * for itself is which card is highlighted, and that is a receipt for a press already
 * sent rather than a fact about the world.
 *
 * ── THE RESTYLE ─────────────────────────────────────────────────────────────
 *
 * This file arrived written against `design/components/*` -- `OpPanel`, `OpRow`,
 * `OpScrim` -- and against the `--op77-*` token set. Neither exists: the shared row
 * components were what coupled five surfaces together in pass 01 and were deleted
 * with it, and the tokens are `--op-*` now. The import alone broke the build, so
 * this is not a restyle of a working page; it is a page that could not be bundled.
 *
 * What it is drawn out of instead is the vocabulary every other surface uses:
 * `.op-bay` for the enclosure, `.op-frame` for a card, `.op-arete` for the lit
 * leading run, `.op-interlace` over what is enclosed, `.op-lift` for the chosen
 * card's bloom, `.op-plane` for the perspective. Per `ui/README.md`, a shape is
 * augmented-ui and a state is one `--aug-border-bg`; NOTHING here writes an accent
 * channel as a literal, because the accent is the operator's -- `design-system/theme.ts`
 * overwrites the triples on `:root` at runtime and a copied `rgba(...)` would simply
 * not follow.
 *
 * A CENTRED SURFACE TAKES NO TILT. `.op-plane > *` defaults `--op-tilt-signed` to
 * 0deg and this page adds no anchor class, so the stage does not rotate: turning a
 * centred plane about its own middle is paper on a spindle, which is the call
 * `FormView` and `InventoryView` both make.
 */

interface Place {
  id: string
  label: string
  district: string
}

const open = ref(false)
const title = ref('')
const about = ref('')
const hint = ref('')
const places = ref<Place[]>([])
/**
 * The card the press landed on, or empty. A RECEIPT, not a step: it is set by the
 * press that has already gone to Lua, and by the arrow keys moving the keyboard's
 * place in the list. Nothing waits on it.
 */
const chosen = ref('')

let release: (() => void) | undefined

/**
 * The card's place in the list, as two digits.
 *
 * TECHNICAL FILLER IS CONTENT -- rule 8 of `ui/README.md`. This is the one mono
 * micro-label on the card and it states something the surface actually knows: which
 * card this is, counted the way the player counts them. It is not invented chrome.
 */
function ordinal(at: number): string {
  return String(at + 1).padStart(2, '0')
}

/* The places go when the room's fade has run, not in the same tick as `open`: wiped
   at once, the bay collapsed to an empty head and faded out like that. */
const WIPE_MS = 240
let wipe: ReturnType<typeof setTimeout> | undefined

function cancelWipe(): void {
  if (wipe !== undefined) clearTimeout(wipe)
  wipe = undefined
}

function close(): void {
  open.value = false
  cancelWipe()
  wipe = setTimeout(() => {
    wipe = undefined
    if (!open.value) blank()
  }, WIPE_MS)
}

function blank(): void {
  open.value = false
  places.value = []
  chosen.value = ''
  title.value = ''
  about.value = ''
  hint.value = ''
}

/** Moves the highlight, wrapping. From nothing, it starts at the end it came from. */
function move(delta: number): void {
  const total = places.value.length
  if (total === 0) return
  const at = places.value.findIndex((place) => place.id === chosen.value)
  if (at === -1) {
    chosen.value = delta > 0 ? places.value[0].id : places.value[total - 1].id
    return
  }
  chosen.value = places.value[(at + delta + total) % total].id
}

function confirm(): void {
  // An INTENT. Lua re-derives which place this is and where it is, and this page
  // stays open until the answer comes back on `spawn:close`.
  if (!open.value || chosen.value === '') return
  emit('opx:spawn:choose', { id: chosen.value })
}

/**
 * Clicking a card IS the choice. One click places you; the highlight is the
 * receipt, not a step. The card is picked first so the highlight lands on the
 * row that was pressed even if the answer takes a moment, and the send is the
 * same `confirm` everything else uses -- there is one path to the wire.
 *
 * A second press is not a second choice: the server rate-limits the id it is
 * sent, and the menu is unmounted by the answer either way.
 */
function pick(id: string): void {
  chosen.value = id
  confirm()
}

function onKeyDown(event: KeyboardEvent): void {
  if (!open.value) return
  // Kept now that the confirm button is gone, which is what it used to guard
  // against: a control with DOM focus handles Enter itself and has prevented the
  // default by the time this sees it, so one press could otherwise spawn twice.
  // Nothing on this surface takes DOM focus today -- a card is a `role="button"`
  // div with no tabindex -- but this is a window-level listener, so the first
  // focusable thing anybody adds would reintroduce the double send silently.
  if (event.defaultPrevented) return

  if (event.key === 'ArrowDown' || event.key === 'ArrowRight') {
    event.preventDefault()
    move(1)
    return
  }
  if (event.key === 'ArrowUp' || event.key === 'ArrowLeft') {
    event.preventDefault()
    move(-1)
    return
  }
  if (event.key === 'Enter') {
    event.preventDefault()
    confirm()
  }
}

useBridge('opx:spawn:open', (payload: Payload) => {
  guard(
    'spawn:open',
    () => {
      const rows: Place[] = []
      for (const entry of records(payload.locations)) {
        const id = text(entry.id)
        if (!id) continue
        rows.push({ id, label: text(entry.label, id), district: text(entry.district) })
      }
      // No places to draw is not a menu: the server only offers a choice it can
      // serve, so this is a configuration that changed under a live session.
      if (rows.length === 0) return

      cancelWipe()
      places.value = rows
      title.value = text(payload.title)
      about.value = text(payload.about)
      hint.value = text(payload.hint)

      chosen.value = ''
      open.value = true

      release?.()
      release = acquireFocus({
        id: 'spawn',
        // THE CHOICE IS MANDATORY, so Escape does nothing on purpose. Supplying a
        // handler at all is the point: without one, bridge/focus.ts releases the
        // owner on Escape and the menu is left on screen with no pointer and no
        // keyboard -- visible, unanswerable, and only the server can end it.
        onEscape: () => {}
      })
    },
    undefined
  )
})

useBridge('opx:spawn:close', (payload: Payload) => {
  guard(
    'spawn:close',
    () => {
      // The reason is Lua's and it has already said it: a toast, in the player's
      // language. This page only takes the menu down.
      void payload
      close()
      release?.()
      release = undefined
    },
    undefined
  )
})

onMounted(() => {
  window.addEventListener('keydown', onKeyDown)
})

onUnmounted(() => {
  cancelWipe()
  window.removeEventListener('keydown', onKeyDown)
  release?.()
})
</script>

<template>
  <div class="room op-ink" :class="{ open }">
    <div class="scrim" :class="{ shown: open }" />

    <div class="stage op-plane">
      <div class="bay op-bay op-arete" data-augmented-ui="tr-clip bl-clip border">
        <div class="bay-inner op-interlace">
          <!-- THE HEAD STAYS, where `MenuView` deleted its own. A menu row says what
               it does; a spawn card says only where it IS, and a grid of place names
               with nothing over it is a list rather than a question. The title Lua
               sends is the question, so it is the one piece of chrome this surface
               cannot drop -- the same call `FormView` makes. -->
          <div class="head">
            <div class="head-text">
              <span class="eyebrow op-eyebrow">{{ eyebrow }}</span>
              <h1 class="op-truncate">{{ title }}</h1>
            </div>
          </div>

          <p v-if="about" class="note op-copy">{{ about }}</p>

          <!-- ONE BAY, ELEVEN CARDS. The enclosure is augmented once and each card is
               augmented for its own cut and ground, asking for the border layer alone
               so it is one pseudo-element each rather than two -- which is the rule
               `ui/README.md` states for the inventory's forty cells and is the same
               trade here. The key is the id Lua sent, so a card that survives a frame
               keeps its element and does not replay the stutter under the pointer. -->
          <ul class="grid">
            <li
              v-for="(place, at) in places"
              :key="place.id"
              class="slot op-enter"
              :style="`--op-slot: ${at}`"
            >
              <div
                class="card op-frame"
                :class="{ 'is-on': place.id === chosen, 'op-lift': place.id === chosen }"
                data-augmented-ui="tr-clip border"
                role="button"
                :aria-pressed="place.id === chosen"
                @click="pick(place.id)"
              >
                <span class="index op-eyebrow" aria-hidden="true">{{ ordinal(at) }}</span>
                <span class="card-text">
                  <span class="label op-label op-truncate">{{ place.label }}</span>
                  <!-- The district, and never the coordinates: what Lua sends is a
                       label and a hint line, and there is nothing here for a page to
                       be tempted to act on. -->
                  <span v-if="place.district" class="district op-value op-truncate">{{ place.district }}</span>
                </span>
              </div>
            </li>
          </ul>

          <!-- WHAT THE KEYS DO, and nothing else. There is no control down here:
               a click on a card IS the spawn, so a button beside it would be a
               second way to send an intent that has already gone -- and a frame
               means "press this" (rule 2), which would have made the grid look
               like a selection waiting on a confirmation. -->
          <div v-if="hint" class="foot">
            <p class="hint op-copy">{{ hint }}</p>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   THE SPAWN MENU -- red, outlined, untilted.

   `MenuView.vue` settled the look and `FormView.vue` is that look centred behind
   a scrim, which is what this surface is: one bounded enclosure the player drives
   with the pointer or with four keys, over a world they cannot touch yet. So this
   file takes the bay, the arete, the interlace and the frame from
   `design-system/` and says only what is true of a SPAWN MENU:

     1. IT IS A GRID, NOT A COLUMN. Eleven places read as a map at two abreast and
        as a scroll at one; a menu strip's single column would put the last four
        below the fold of a 1080p surface, and the whole point of the screen is to
        see the choices at once.
     2. THE CHOSEN CARD DOES NOT STEP OUT OF THE COLUMN. `--op-pop` is a lateral
        move away from the anchored edge, and this surface is anchored to none --
        there is no edge for it to step away from, and in a grid it would shunt a
        card into its neighbour. The frame, the ground and the bloom carry the
        state instead, which is `.op-frame.is-on` plus `.op-lift` and nothing local.
     3. THERE IS NO TILT. A centred plane rotated about its own middle sends half
        toward the player and half away. `.op-plane` gives the perspective and the
        containment; no anchor class means `--op-tilt-signed` stays 0deg.

   EVERY COLOUR IS A TOKEN. The accent is the server's -- `modules/theme` sends
   the triples and `design-system/theme.ts` writes them onto `:root` -- so an
   `rgba(232, 67, 79, ...)` written here would be the one surface that ignored an
   operator's accent, with nothing to warn anybody. The only literals below are
   black: the scrim's own ground comes from `--op-plate-quiet` and the ink from
   `--op-ink`.
   ========================================================================== */

/* The wash under the menu. The same one `FormView` draws, and for the same
   reason: this surface takes the cursor and the keyboard, so the world behind it
   has to stop looking like something the player can still act on. `--op-plate-quiet`
   is the house ground at its lightest weight, so a theme that darkens the surface
   darkens this with it. */
.scrim {
  position: absolute;
  inset: 0;
  background: var(--op-plate-quiet);
  opacity: 0;
  transition: opacity var(--op-dur) var(--op-ease);
}

.scrim.shown {
  opacity: 1;
}

.room {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  opacity: 0;
  pointer-events: none;
  transition: opacity var(--op-dur-fast) linear;
}

.room.open {
  opacity: 1;
  pointer-events: auto;
}

/* =============================================================================
   THE STAGE -- `.op-plane` carries the perspective, the paint containment and
   the bleed a bloom needs inside it. It is on the WRAPPER and never on the bay:
   on the bay itself every descendant would get its own vanishing point.

   No `.op-anchor-*`: a centred surface takes neither, which is how
   `design-system/surface.css` says "this one does not tilt".
   ========================================================================== */
.stage {
  position: relative;
  display: flex;
  width: min(880px, calc(100vw - var(--op-inset-x) * 2));
  max-height: calc(100vh - var(--op-inset-y) * 2);
}

/* =============================================================================
   THE BAY -- the enclosure. Two opposite corners cut, which reads as a plate
   slid into place; `.op-arete` lights the leading run across the border layer.
   ========================================================================== */
.bay {
  position: relative;
  flex: 1;
  min-width: 0;
  /* A COLUMN, so the stage's max-height reaches the grid. As a block the bay was as
     tall as its content and `.bay-inner`'s `max-height: inherit` inherited
     nothing: past a screenful of places the grid never scrolled, and the last cards
     and the hint were cut off by the bay's own clip. */
  display: flex;
  flex-direction: column;
  /* THE DIAL IS TURNED ON, with `FormView`'s caveat: the scrim means this bay was
     never the one washing out, so it needs to be told apart from that dim rather
     than held against daylight. Quiet, on `--op-plate`'s own channels, so the
     menu, the form and this are one ground at three weights. */
  background: rgba(var(--op-plate-rgb), var(--op-spawn-veil, 0.58));
}

.bay-inner {
  position: relative;
  z-index: 1;
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  min-height: 0;
  max-height: inherit;
}

/* =============================================================================
   THE HEAD -- the question. One rule under it, which is not an enclosure: it is
   the only thing relating the question to the grid beneath it.
   ========================================================================== */
.head {
  display: flex;
  align-items: flex-end;
  gap: var(--op-space-4);
  min-width: 0;
  /* The trailing edge pays for the chamfer, so a long title never runs under it. */
  padding: var(--op-space-3) calc(var(--op-space-4) + var(--op-cut-lg))
    var(--op-space-2) calc(var(--op-space-4) + var(--op-rule));
  border-bottom: 1px solid var(--op-red-idle);
}

.head-text {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  margin-right: auto;
  min-width: 0;
}

.eyebrow {
  color: var(--op-red-deep);
}

/* The house device. `FormView` draws its own for the same reason: it is two
   characters of type, not a component. */
.eyebrow::before {
  content: "//";
  margin-right: 0.7em;
  color: var(--op-red);
  font-weight: 700;
  letter-spacing: -0.06em;
}

.head h1 {
  margin: 0;
  font: 700 var(--op-fs-head) / 1.1 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  text-transform: uppercase;
  color: var(--op-red-text);
}

/* The sentence under the question. Prose, and the player's rather than an
   instrument's, so it takes the legibility grey. */
.note {
  margin: 0;
  padding: var(--op-space-3) calc(var(--op-space-4) + var(--op-cut-lg)) 0
    calc(var(--op-space-3) + var(--op-rule));
  color: var(--op-text-dim);
}

/* =============================================================================
   THE GRID -- two abreast where there is room, one where there is not. Eleven
   cards is two columns of six on a 1080p surface, which is the whole catalogue
   at a glance; below that it degrades to a single scrolling column rather than
   to cards too narrow to carry a place name.
   ========================================================================== */
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
  gap: var(--op-space-1);
  align-content: start;
  margin: 0;
  padding: var(--op-space-3) var(--op-space-4) var(--op-space-3)
    calc(var(--op-space-3) + var(--op-rule));
  list-style: none;
  min-height: 0;
  overflow: hidden auto;
  /* No scrollbar. There is no OS chrome inside a CEF surface worth drawing, and
     a scrollbar is a second vertical rule beside the bay's own cut edge. */
  scrollbar-width: none;
}

.grid::-webkit-scrollbar {
  display: none;
}

/* THE ENTRANCE IS ON THE SLOT, NOT ON THE CARD, which is the lesson `MenuView`
   paid for: a card's classes change when the highlight moves, and an
   `animation-name` that differs between two states is cancelled and restarted by
   the change -- so both the card being left and the card being landed on would
   replay the stutter from behind their delay and be invisible for the whole wait.
   The <li> is what the keyed v-for creates and its classes say nothing about the
   highlight. */
.slot {
  display: flex;
  min-width: 0;
}

/* =============================================================================
   A CARD -- a control, so it is a closed box: a thin frame with the top-right
   corner chamfered. `.op-frame` is the frame, the ground, the hover and the
   chosen state; what is here is what a spawn card is SHAPED like.
   ========================================================================== */
.card {
  position: relative;
  flex: 1;
  display: flex;
  align-items: center;
  gap: var(--op-space-3);
  min-width: 0;
  /* The right edge pays for the chamfer so a long place name never runs under it. */
  padding: var(--op-space-2) calc(var(--op-space-3) + var(--op-cut-sm))
    calc(var(--op-space-2) + 1px) var(--op-space-3);
  cursor: pointer;
  transition: color var(--op-dur-fast) linear;
}

/* The index column is held open whether or not it is read, so every label on the
   grid lands on one x within its column. */
.index {
  flex: none;
  width: 2ch;
  color: var(--op-red-deep);
  font-variant-numeric: tabular-nums;
}

.card-text {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 0;
}

/* The hint line. Grey, because the district is context for the place name above
   it and not a second reading of it. */
.district {
  color: var(--op-text-dim);
}

/* --- CHOSEN ------------------------------------------------------------------
   `.op-frame.is-on` lights the frame and the ground and `.op-lift` blooms it. A
   filter is affordable here for the reason `shapes.css` gives: this surface
   repaints when the player presses something, not thirty times a second. What is
   local is the letter-spacing, which is the same half-step `MenuView` gives its
   chosen row. */
.card.is-on .label {
  letter-spacing: 0.055em;
  text-shadow: var(--op-ink), 0 0 10px var(--op-red-glow);
}

.card.is-on .index,
.card.is-on .district {
  color: var(--op-red-text);
}

/* =============================================================================
   THE FOOT -- one line of type saying what the keys do, and no control. The
   trailing padding still pays for the bay's bottom-left chamfer even though
   nothing sits out there now: the cut is on the ENCLOSURE, so a sentence that
   wrapped far enough would still run under it.
   ========================================================================== */
.foot {
  display: flex;
  align-items: center;
  min-width: 0;
  padding: var(--op-space-3) calc(var(--op-space-3) + var(--op-cut-lg))
    calc(var(--op-space-3) + var(--op-cut-lg)) calc(var(--op-space-3) + var(--op-rule));
  border-top: 1px solid var(--op-red-idle);
}

/* The one place this surface wraps: a hint is a sentence. */
.hint {
  margin: 0;
  color: var(--op-text-faint);
  letter-spacing: var(--op-track-label);
  font-family: var(--op-font-mono);
  white-space: normal;
}
</style>
