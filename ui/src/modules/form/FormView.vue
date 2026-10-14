<script setup lang="ts">
import { computed, nextTick, onUnmounted, ref } from 'vue'
import type { ObjectDirective } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { num, text, records, own } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

// The eyebrow from the catalogue, so a French player does not read `FORM`; the
// English word only before the catalogue has reached the page.
const { t, has } = useLocale()
const eyebrow = computed(() => (has('form.eyebrow') ? t('form.eyebrow') : 'FORM'))

/**
 * THE FORM -- port of `opx77_input/web/{index.html,input.css,input.js}`.
 *
 * Text, choice and slider answered together in one modal. Like the menu it is a
 * renderer: Lua holds the authoritative buffer, runs `maxLength`, `charset`, `pattern`
 * and `required`, and answers every keystroke with the buffer it ACCEPTED. The page
 * reports candidates.
 *
 * That round trip is not caution, it is the contract in `form-spec.md`: "A refused
 * keystroke is not merely hidden: the accepted buffer stays as it was and the page is
 * told to put it back." A field that kept its own text would be showing a value the
 * server has already refused.
 *
 * Unlike the menu, this page always held the keyboard -- `input.js` forwarded six keys
 * to Lua and left every other key to the focused <input>. That is unchanged here, down
 * to the one rule that makes it work: LEFT and RIGHT belong to the caret unless the
 * frame said the focused row spins.
 *
 * -- DESIGN PASS 02 -----------------------------------------------------------
 *
 * THIS SURFACE NOW DRAWS ITS OWN FRAME, ITS OWN FIELDS AND ITS OWN KEYCAPS. It was the
 * last view still wearing pass 01: an `OpPanel` bay with `OpField` rows and `OpKeyCap`
 * caps, all three of them augmented elements filling the chosen row with `--op77-accent`
 * -- which is Night City yellow under `.op-theme-city`, on a surface whose neighbours
 * have all gone red and unfilled. It read as a screen from the previous build.
 *
 * The three components are not edited and not deleted: `PanelView.vue` and the entry
 * flow still render them, and changing a shared component changes every surface at once.
 * So this file carries a local copy of the row while the pass is being settled, exactly
 * as `MenuView.vue` says it does and for the same reason -- when the pass is agreed the
 * frame, the row and the cap go back into `design/` together, every surface takes them,
 * and the local copies are deleted in one go.
 *
 * THE SCRIM STAYS, and it is drawn here rather than imported. `InventoryView.vue`
 * dropped its scrim on the grounds that it was the largest fill on a surface with no
 * fills, and it is right about an inventory -- a bag is read at a glance and the player
 * is still standing in the world. A form is TYPED INTO. The player is reading their own
 * characters back one at a time to see which ones Lua kept, and a street moving behind
 * that line is the one backdrop this runtime cannot ask them to read through. The scrim
 * is also the `dim` flag's only consumer: Lua sends it per form and it still means what
 * it meant.
 *
 * Nothing about the protocol changed. Same channels, same handle guard, same six keys,
 * same candidate-only edits. Only what the player sees.
 *
 * -- THE ROUND TRIP IS NOT INSTANT, AND THE FIELD USED TO PAY FOR IT ------------
 *
 * `:value` is re-applied to the DOM on EVERY re-render of this input, unconditionally:
 * Vue forces the `value` prop through even when the bound string has not changed, and
 * `patchDOMProp` then writes it whenever the element disagrees. So between the `input`
 * event and Lua's answer -- one page-to-Lua-to-page trip, which at creator framerates
 * is longer than the gap between two keystrokes -- ANY frame that lands rewrites the
 * line to the buffer Lua held BEFORE the character. Under the first character that
 * buffer is the empty string, the placeholder comes back, and the field reads as empty
 * while the player is typing into it.
 *
 * The answer is not to let the page own the buffer -- it must not, Lua truncates and
 * filters and the line has to end up showing exactly what Lua kept. It is to make the
 * frames distinguishable. Every edit leaves here stamped with a sequence; every frame
 * carries back the last sequence each field was RULED ON. A frame that has caught up
 * is the answer to what the player last typed and replaces the line, refusal included.
 * A frame that has not is older than the caret and leaves the line alone -- the page
 * goes on drawing the candidate it reported, which is already on screen, so nothing is
 * written and the caret does not move.
 *
 * A candidate is a string this page HOLDS, never one it answers with. It lives for at
 * most one round trip, it is dropped the instant Lua rules on it, and `values` on the
 * submit is built by Lua out of its own buffers -- nothing here is ever read back.
 */

type Handle = string | number

interface Field {
  id: string
  kind: 'text' | 'choice' | 'slider'
  label: string
  /** Text kind: the buffer Lua accepted. The count under the line is this, and only
      this: it is a statement about what Lua kept, so it may never count a candidate. */
  buffer: string
  /** Text kind: what the line must show right now -- `buffer`, or the candidate this
      page reported while Lua has not yet ruled on it. Never sent anywhere. */
  shown: string
  /** Choice and slider: the value as Lua rendered it, suffix and all. */
  value: string
  /** Slider: the number, for the track. See the note on `suffix` in the report. */
  number: number
  min: number
  max: number
  placeholder: string
  /** `12/24`, drawn under the focused text field. */
  count: string
  /** LEFT and RIGHT change this row's value rather than moving the caret. */
  spin: boolean
  on: boolean
}

interface KeyHint {
  key: string
  label: string
}

/** The six keys input.js forwards. Everything else is the focused field's. */
const KEYS: Record<string, string> = {
  ArrowUp: 'up',
  ArrowDown: 'down',
  ArrowLeft: 'left',
  ArrowRight: 'right',
  Enter: 'enter'
}

const ANCHORS: Record<string, string> = {
  'center': 'anchor-center',
  'top-left': 'anchor-top-left',
  'top-right': 'anchor-top-right',
  'left': 'anchor-left',
  'right': 'anchor-right'
}

const handle = ref<Handle | null>(null)
const open = ref(false)
const title = ref('')
const note = ref('')
const hint = ref('')
const status = ref('')
const statusBad = ref(false)
const fields = ref<Field[]>([])
const keys = ref<KeyHint[]>([])
const anchor = ref('anchor-center')
const width = ref(420)
const dim = ref(true)

const listEl = ref<HTMLElement | null>(null)

/* The keystrokes this page has reported and Lua has not yet ruled on: field id ->
   the sequence it went out under and the candidate it carried. Deliberately not
   reactive -- reporting a candidate must NOT re-render, because a re-render is what
   writes the line, and the line already holds the character the player typed. */
const pending = new Map<string, { seq: number; text: string }>()

/** Monotonic across the whole surface. Only the ordering matters, not the value. */
let stamp = 0

const stripStyle = computed(() => `width: ${width.value}px`)

const focused = computed(() => fields.value.find((field) => field.on))

/** A right-anchored surface reads its leading edge as the right one, so the chamfers,
    the arete and the focused field's step all mirror. Straight from menu.css. */
const railEnd = computed(() => anchor.value.endsWith('right'))

/** Lua counts characters and JS counts UTF-16 units: a surrogate pair is one character
    on both sides once its low half is dropped. Straight from input.js. */
function characters(value: string): number {
  return value.replace(/[\uDC00-\uDFFF]/g, '').length
}

/** input.js sized the plate to its content so the frame never outran the text, and
    `OpField` kept doing it. A LENGTH, not a value: nothing derived here is ever sent. */
function chars(field: Field): number {
  // `shown`, not `buffer`: the plate sizes to the text that is actually on it, or the
  // frame trails a round trip behind the caret sitting inside it.
  return Math.max(field.shown.length, field.placeholder.length) + 1
}

/** The slider's rule, as a width. Clamped because a frame can legitimately carry a
    number outside its own bounds for one frame while Lua is still deciding. */
function fill(field: Field): string {
  const span = field.max - field.min
  if (span <= 0) return '0%'
  const ratio = (field.number - field.min) / span
  return `${Math.max(0, Math.min(1, ratio)) * 100}%`
}

function isHandle(value: unknown): value is Handle {
  return typeof value === 'string' || typeof value === 'number'
}

function mine(payload: Payload): boolean {
  return handle.value !== null && payload.handle === handle.value
}

function readConfig(payload: Payload): void {
  anchor.value = own(ANCHORS, text(payload.anchor)) ?? ANCHORS['center']
  const wide = num(payload.width)
  if (wide > 0) width.value = Math.round(wide)
  dim.value = payload.dim !== false
}

function readFrame(payload: Payload): void {
  title.value = text(payload.title) || 'INPUT'
  note.value = text(payload.note)
  hint.value = text(payload.hint)
  status.value = text(payload.status)
  statusBad.value = payload.statusBad === true

  keys.value = records(payload.keys).map((cap) => ({
    key: text(cap.key),
    label: text(cap.label)
  }))

  const drawn = new Set<string>()

  fields.value = records(payload.rows).map((row) => {
    const named = text(row.kind, 'text')
    const kind: Field['kind'] = named === 'choice' || named === 'slider' ? named : 'text'
    const id = text(row.id)
    const buffer = text(row.text)
    drawn.add(id)

    // THE RECONCILIATION. `ack` is the last keystroke Lua ruled on for this field; a
    // frame that has reached the sequence still in flight IS the answer to it, so the
    // candidate is dropped and the line snaps to what Lua kept -- shorter, filtered,
    // or unchanged because the character was refused. A frame that has not reached it
    // is older than the caret, and re-drawing the candidate leaves the DOM untouched.
    const ack = num(row.ack)
    const held = pending.get(id)
    let shown = buffer
    if (held !== undefined) {
      if (ack >= held.seq) pending.delete(id)
      else shown = held.text
    }
    // `max` is the field's own bound either way: `maxLength` on a text field, the top of
    // the range on a slider. A row has one kind, so the two never meet.
    const min = num(row.min)
    const max = num(row.max, kind === 'slider' ? 100 : 0)
    return {
      id,
      kind,
      label: text(row.label),
      buffer,
      shown,
      value: text(row.value),
      // `fill` is what opx77_input already sends; `number` is preferred when Lua sends
      // it, because a value re-derived from a rounded ratio would not step evenly.
      number: typeof row.number === 'number' ? row.number : min + num(row.fill) * (max - min),
      min,
      max: kind === 'slider' ? max : 100,
      placeholder: text(row.placeholder),
      // A display of the buffer Lua sent, counted the way Lua counts it. Nothing
      // derived here ever leaves the page.
      count: kind === 'text' && max > 0 ? `${characters(buffer)}/${Math.round(max)}` : '',
      spin: row.spin === true,
      on: row.on === true
    }
  })

  // A candidate for a field this frame no longer draws can never be answered, and a
  // stuck entry would freeze that line against every frame after it.
  for (const id of pending.keys()) {
    if (!drawn.has(id)) pending.delete(id)
  }

  // input.js put the caret in the focused text field and blurred everything otherwise,
  // so the document -- not a field -- keeps the keyboard and keydown still fires.
  void nextTick(syncCaret)
}

function syncCaret(): void {
  guard('form:caret', () => {
    const root = listEl.value
    if (!root) return
    const field = focused.value
    if (field && field.kind === 'text') {
      const input = root.querySelector<HTMLInputElement>(`[data-field="${CSS.escape(field.id)}"] input`)
      if (input && document.activeElement !== input) {
        input.focus()
        // DOWN onto the second name lands the caret wherever that element was last
        // left, which for a field carrying a draft is the front of it -- so the next
        // character is typed in front of the name instead of after it. The end is the
        // only position arriving at a line by keyboard can mean.
        const end = input.value.length
        input.setSelectionRange(end, end)
      }
      return
    }
    const active = document.activeElement
    if (active instanceof HTMLElement) active.blur()
  }, undefined)
}

/** How long a closed form keeps its rows: past the room's fade, with room to spare.
    They were wiped in the same tick as `open`, so the frame collapsed to its title and
    faded out like that -- a flicker on every Confirm. Nothing can redraw them meanwhile:
    the handle is gone, so `mine()` drops any late frame. */
const WIPE_MS = 240
let wipe: ReturnType<typeof setTimeout> | undefined

function cancelWipe(): void {
  if (wipe !== undefined) clearTimeout(wipe)
  wipe = undefined
}

function blank(): void {
  open.value = false
  // Nothing in flight survives the form it was typed into: the next form's fields may
  // carry the same ids, and a candidate held over would draw one form's text on another.
  pending.clear()
  const active = document.activeElement
  if (active instanceof HTMLElement) active.blur()
  cancelWipe()
  wipe = setTimeout(() => {
    wipe = undefined
    if (open.value) return
    fields.value = []
    keys.value = []
    note.value = ''
    hint.value = ''
    status.value = ''
    statusBad.value = false
  }, WIPE_MS)
}

let release: (() => void) | undefined

function keyDown(event: KeyboardEvent): void {
  // Escape is bridge/focus.ts's, in the capture phase.
  if (event.key === 'Escape') return
  const key = KEYS[event.key]
  if (key === undefined) return
  // The one rule that lets a typed line and an arrow-stepped list share a surface.
  if ((key === 'left' || key === 'right') && focused.value?.spin !== true) return
  event.preventDefault()
  emit('opx:form:key', { handle: handle.value, key, repeat: event.repeat === true })
}

function listen(on: boolean): void {
  if (on) window.addEventListener('keydown', keyDown)
  else window.removeEventListener('keydown', keyDown)
}

useBridge('opx:form:open', (payload: Payload) => {
  guard('form:open', () => {
    if (!isHandle(payload.handle)) return
    release?.()
    // Lua cancels the live form when a caller re-opens on the same surface, and the
    // acknowledgements start again from whatever the new form's fields carry.
    pending.clear()
    cancelWipe()
    handle.value = payload.handle
    readConfig(payload)
    readFrame(payload)
    open.value = true
    listen(true)
    release = acquireFocus({
      id: 'form',
      // Escape is `cancel` in `opx77_input/client/main.lua`; Lua raises the answer with
      // `action = "cancel"` and closes. The page does not decide that.
      onEscape: () => emit('opx:form:dismiss', { handle: handle.value })
    })
  }, undefined)
})

useBridge('opx:form:frame', (payload: Payload) => {
  guard('form:frame', () => {
    if (!mine(payload)) return
    readFrame(payload)
  }, undefined)
})

useBridge('opx:form:close', (payload: Payload) => {
  guard('form:close', () => {
    if (payload.handle !== undefined && !mine(payload)) return
    handle.value = null
    blank()
    listen(false)
    release?.()
    release = undefined
  }, undefined)
})

onUnmounted(() => {
  cancelWipe()
  listen(false)
  release?.()
})

/** A CANDIDATE buffer, never an accepted one. Lua answers with a frame carrying the
    text it kept, which may be shorter, unchanged, or the same string back -- and the
    sequence this went out under, which is how that frame is told from an older one. */
function edit(field: Field, value: string): void {
  stamp += 1
  pending.set(field.id, { seq: stamp, text: value })
  emit('opx:form:edit', { handle: handle.value, id: field.id, seq: stamp, text: value })
}

/* -- THE CARET, WHEN LUA'S ANSWER IS NOT WHAT IS ON THE LINE -------------------
   Writing `value` on a focused input drops the caret at the end, so a refusal or a
   truncation arriving mid-word would throw the player to the end of their own name.
   Vue owns the write -- `:value` is the binding and it stays -- so the caret is put
   back around it: captured before the element is patched, restored after, and only
   when the patch actually moved the text.

   The rule is the length delta, not the old offset. Lua refusing the character just
   typed shortens the line by one and the caret goes back one, which is where the
   refused character would have been; Lua truncating a tail leaves the caret where it
   was unless it was inside the part that went. */
const carets = new WeakMap<HTMLInputElement, { was: string; at: number }>()

const vCaret: ObjectDirective<HTMLInputElement> = {
  beforeUpdate(el) {
    if (document.activeElement !== el) return
    carets.set(el, { was: el.value, at: el.selectionStart ?? el.value.length })
  },
  updated(el) {
    const held = carets.get(el)
    carets.delete(el)
    if (held === undefined || document.activeElement !== el) return
    if (held.was === el.value) return
    const at = held.at - (held.was.length - el.value.length)
    const to = Math.max(0, Math.min(el.value.length, at))
    el.setSelectionRange(to, to)
  }
}

/** The choice arrows, which are LEFT and RIGHT by another name. */
function step(field: Field, direction: -1 | 1): void {
  emit('opx:form:step', { handle: handle.value, id: field.id, direction })
}

/** The player pointed at a field. Lua moves its own cursor; this does not. */
function focusField(field: Field): void {
  if (field.on) return
  emit('opx:form:focus', { handle: handle.value, id: field.id })
}
</script>

<template>
  <div class="room" :class="{ open }">
    <div v-if="dim" class="scrim" :class="{ shown: open }" />
    <div class="strip" :class="[anchor, { end: railEnd }]" :style="stripStyle">
      <div
        class="bay op-bay op-arete"
        :class="{ 'is-end': railEnd }"
        data-augmented-ui="tr-clip bl-clip border"
      >
        <div class="bay-inner">
          <!-- THE HEAD STAYS, where `MenuView.vue` deleted its own. A menu row says what
               it does; a form field says only what it is CALLED, and "NAME" over an empty
               line is not a question. The title Lua sends is the question, so it is the
               one piece of chrome this surface cannot drop. -->
          <div class="head">
            <div class="head-text">
              <!-- The `//` device, drawn locally: `.op77-eyebrow` in tokens.css colours
                   its own `::before` with `--op77-accent`, which is yellow under
                   `.op-theme-city`. Otherwise identical, and that is the only reason. -->
              <span class="eyebrow">{{ eyebrow }}</span>
              <h1 class="op-truncate">{{ title }}</h1>
            </div>
          </div>

          <p v-if="note" class="note">{{ note }}</p>

          <!-- A KEYED v-for on Lua's own row id, so a field that survives a frame keeps
               its element: the caret stays where the player put it, and the boot-in does
               not re-run under them while they type. -->
          <ul ref="listEl" class="list">
            <li
              v-for="field in fields"
              :key="field.id"
              class="slot"
              :data-field="field.id"
            >
              <div
                class="field"
                data-augmented-ui="tr-clip border"
                :class="[`kind-${field.kind}`, { on: field.on }]"
                @click="focusField(field)"
              >
                <span class="label op-label op-truncate">{{ field.label }}</span>
                <span class="cell">
                  <!-- NO `v-model`, here or anywhere on this surface. `:value` is what
                       Lua's last word on this field allows the line to show and `@input`
                       reports a candidate; the two are deliberately not the same string.
                       `shown` is `buffer` except across the one round trip in which Lua
                       has not yet ruled on the character under the caret -- see the
                       header. The input stays fully controlled either way. -->
                  <input
                    v-if="field.kind === 'text'"
                    v-caret
                    class="entry"
                    type="text"
                    spellcheck="false"
                    autocomplete="off"
                    :value="field.shown"
                    :placeholder="field.placeholder"
                    :style="{ '--chars': chars(field) }"
                    @input="edit(field, ($event.target as HTMLInputElement).value)"
                  >
                  <!-- A RULE, NOT A GAUGE: two pixels of red under the number, per
                       `InventoryView.vue`'s load rule. The filled bar it replaces was a
                       fill, and there are none left on this surface. -->
                  <span v-if="field.kind === 'slider'" class="rule">
                    <i :style="{ width: fill(field) }" />
                  </span>
                  <span v-if="field.kind !== 'text'" class="value op-value op-truncate">{{ field.value }}</span>
                  <!-- HELD IN THE ROW ON EVERY FIELD, SHOWN ON THE FOCUSED ONE. Mounted only on
                       focus, it arrived in a cell that packs to the right and shoved the
                       typed line left by its own width the moment the player tabbed in. -->
                  <span v-if="field.kind === 'text' && field.count" class="count" :class="{ quiet: !field.on }">
                    {{ field.count }}
                  </span>
                  <!-- LEFT and RIGHT with a mouse. Lua reads both routes as the same
                       `step` intent and answers with the value it settled on. -->
                  <span v-if="field.kind === 'choice'" class="marks">
                    <button class="mark" type="button" @click.stop="step(field, -1)">&lsaquo;</button>
                    <button class="mark" type="button" @click.stop="step(field, 1)">&rsaquo;</button>
                  </span>
                </span>
              </div>
            </li>
          </ul>

          <div v-if="hint || status || keys.length" class="foot">
            <p v-if="hint" class="hint op-copy">{{ hint }}</p>
            <p v-if="status" class="status" :class="{ bad: statusBad }">{{ status }}</p>
            <div v-if="keys.length" class="keys">
              <span v-for="cap in keys" :key="cap.key" class="key">
                <kbd class="cap" data-augmented-ui="tr-clip border">{{ cap.key }}</kbd>
                <span class="cap-label">{{ cap.label }}</span>
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   DESIGN PASS 02 -- RED, OUTLINED, TILTED.

   `MenuView.vue`'s style block is the spec and this is that idiom applied to a
   form. The two surfaces are the same thing seen twice -- a bounded column of
   controls the player drives with five keys -- so this one takes the enclosure,
   the interlace and the row, and the places it differs are the places a field
   differs from a menu row:

     1. THE FOCUSED FIELD DOES NOT LEAVE THE PLANE. On the strip the chosen row
        steps `--pop` across AND 14px toward the player, and it is that surface's
        best move. Here the chosen row is the one being TYPED INTO: a Z step under
        `perspective` resamples the glyphs a caret is sitting between, and the
        player is reading those glyphs back one at a time to see which ones Lua
        kept. The lateral step and the bloom stay, the Z is dropped, and that is
        the whole of the difference.
     2. A CENTRED FORM DOES NOT TILT. The tilt's sign and origin are derived from
        the edge a surface is anchored to, and a form ships centred -- anchored to
        none. Rotating a centred plane about its own middle sends half of it toward
        the player and half away, which is paper on a spindle rather than a surface
        receding; `InventoryView.vue` makes the same call for the same reason. The
        four menu anchors keep the tilt about their own edge.
     3. THERE IS ONE FILL LEFT AND IT IS A CARET. The browser draws it, it is one
        pixel wide, and it is the only thing here allowed to blink.
   ========================================================================== */

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
  opacity: 0;
  pointer-events: none;
  transition: opacity var(--op-dur-fast) linear;
}

.room.open {
  opacity: 1;
  pointer-events: auto;
}

/* =============================================================================
   THE STRIP -- carries the perspective so the frame inside it is the plane that
   tilts. On the strip and not the frame: perspective on the frame would give every
   descendant its own vanishing point. It is declared for every anchor and spent by
   four of them; a centred form sets `--tilt: 0deg` and the property costs nothing.
   ========================================================================== */
.strip {
  position: absolute;
  display: flex;
  max-width: calc(100vw - var(--op-inset-x) * 2);
  perspective: var(--op-persp);
  /* Nothing inside can affect layout or paint outside it, so the compositor never
     has to consider the rest of the surface when one field changes. */
  contain: layout paint style;
}

/* Where a form ships, and the one anchor with no edge to turn about. The focused
   field still steps, because a step across the column is not a rotation. */
.anchor-center {
  left: 50%;
  top: 50%;
  transform: translate(-50%, -50%);
  --pop: 10px;
  --tilt: 0deg;
  --origin: center center;
}

/* The other four are opx77_menu's anchors, for a caller that wants the form where
   the list before it sat -- so they take the menu's tilt about the same edges. */
.anchor-top-left,
.anchor-left {
  left: var(--op-inset-x);
  --pop: 10px;
  --tilt: var(--op-tilt);
  --origin: left center;
}

.anchor-top-right,
.anchor-right {
  right: var(--op-inset-x);
  --pop: -10px;
  --tilt: calc(var(--op-tilt) * -1);
  --origin: right center;
}

.anchor-top-left,
.anchor-top-right {
  top: var(--op-inset-y);
}

.anchor-left,
.anchor-right {
  top: 33vh;
}

/* =============================================================================
   THE FRAME -- no fill.
   ========================================================================== */
.bay {
  position: relative;
  flex: 1;
  min-width: 0;
  /* THE DIAL IS TURNED ON, with this surface's own caveat still standing: the
     scrim behind a form means it was never the one washing out, and the dial sat
     at 0 for that reason. It moves anyway, because the owner asked for a ground
     under everything carrying text and a form that is the one unfilled panel
     among filled ones is a surface that looks unfinished rather than austere.

     QUIET, not full strength, and that is the difference the scrim earns: a form
     is already sitting on a dim, so it needs to be told apart from that dim
     rather than held against daylight. The rgb is `--op-plate`'s, as with the
     menu and the toasts, so the three are one ground. */
  background: rgba(var(--op-plate-rgb), var(--op-form-veil, 0.58));
  transform-origin: var(--origin, center center);
  transform: rotateY(var(--tilt, 0deg));
  /* THE SHAPE AND THE ARETE ARE augmented-ui NOW. This was a six-point
     `clip-path` plus a pair of inset shadows -- an arete on the leading corner
     and the red ring -- because an inset shadow is the only stroke a clip does
     not shear. `.op-bay` cuts the two corners and `.op-arete` lights the leading
     run across the border layer, which is the same picture with no polygon to
     keep in step with `--op-cut-lg`. */
}

/* Mirrored for a right-anchored strip: the cuts and the arete follow the leading
   edge, which over there is the right one. */
/* Mirrored for a right-anchored strip: `.op-arete.is-end` turns the gradient
   round so the lit run follows the leading edge, which over there is the right
   one. The cut corners are the same two either way. */

.bay-inner {
  position: relative;
  z-index: 1;
  display: flex;
  flex-direction: column;
  min-height: 0;
  /* THE BLACK SHADOW, once for the whole surface. A `text-shadow` INHERITS, so this
     one declaration carries the title, the note, the labels, the typed line, the
     hint and the caps. It is the honest fix for an unbacked panel: it darkens the
     two pixels around a letter instead of putting a box behind the row. It sat on
     `.head` until now, which handed it to the title and to nothing else: every
     field, value, hint and keycap under the head was drawn without it. */
  text-shadow:
    0 1px 2px rgba(0, 0, 0, 0.95),
    0 0 9px rgba(0, 0, 0, 0.8);
}

/* The interlace. It is over the panel in every frame of the reference and it is
   what stops an unfilled surface reading as a web page floating in the air. One
   static gradient on a pseudo-element nothing else was using, no transition, so it
   costs a single paint for the life of the form. `pointer-events: none` is
   load-bearing here in a way it is not on the menu: the caret is placed by
   clicking THROUGH this. */
.bay-inner::before {
  content: "";
  position: absolute;
  inset: 0;
  z-index: 2;
  pointer-events: none;
  background: repeating-linear-gradient(
    to bottom,
    var(--op-interlace) 0 1px,
    transparent 1px 3px
  );
}

/* =============================================================================
   THE HEAD -- type and one rule. The rule is not an enclosure: it is the only
   thing relating the question to the fields under it.
   ========================================================================== */
.head {
  display: flex;
  align-items: flex-end;
  gap: var(--op-space-3);
  min-width: 0;
  /* The trailing edge pays for the chamfer, so a long title never runs under it. */
  padding: var(--op-space-3) calc(var(--op-space-4) + var(--op-cut-lg))
    var(--op-space-2) calc(var(--op-space-4) + var(--op-rule));
  border-bottom: 1px solid var(--op-red-idle);
}

/* On a right-anchored form the cut is over the title rather than past it. */
.strip.end .head {
  padding-left: calc(var(--op-space-4) + var(--op-cut-lg));
  padding-right: var(--op-space-4);
}

.head-text {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  min-width: 0;
}

.eyebrow {
  font: 700 var(--op-fs-micro) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  text-transform: uppercase;
  color: var(--op-red-deep);
}

.eyebrow::before {
  content: "//";
  margin-right: 0.7em;
  color: var(--op-red);
  font-weight: 700;
  letter-spacing: -0.06em;
}

.head h1 {
  margin: 0;
  font: 700 var(--op-fs-lead) / 1.1 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  text-transform: uppercase;
  color: var(--op-red-text);
}

/* The sentence under the question. It is prose and it is the player's, not an
   instrument's, so it takes the legibility grey rather than a rung of the ramp. */
.note {
  margin: 0;
  padding: var(--op-space-3) calc(var(--op-space-4) + var(--op-cut-lg)) 0
    calc(var(--op-space-3) + var(--op-rule));
  font: 400 var(--op-fs-body) / 1.35 var(--op-font-body);
  color: var(--op-text-dim);
  text-shadow:
    0 1px 2px rgba(0, 0, 0, 0.95),
    0 0 9px rgba(0, 0, 0, 0.8);
}

/* =============================================================================
   THE LIST -- it never scrolls: Lua sends every field of the form at once.
   ========================================================================== */
.list {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  margin: 0;
  /* The trailing padding is the focused field's runway: it leaves the column by
     `--pop` and has to land inside the bay, which clips. */
  padding: var(--op-space-3) var(--op-space-4) var(--op-space-3)
    calc(var(--op-space-3) + var(--op-rule));
  list-style: none;
  min-height: 0;
}

.slot {
  display: flex;
  min-width: 0;
}

/* =============================================================================
   A FIELD -- a closed 1px frame with a chamfered top-right corner, a label and a
   value. There is nothing behind it and there never will be.

   `border-image-width` is 8px while `border-width` is 1px: the image draws its 8px
   corner tiles while layout only reserves one, so the chamfer is full size and the
   field still sits on a 1px box.
   ========================================================================== */
.field {
  position: relative;
  flex: 1;
  display: flex;
  align-items: center;
  gap: var(--op-space-3);
  min-width: 0;
  padding: var(--op-space-2) var(--op-space-3) calc(var(--op-space-2) + 1px);
  color: var(--op-red-text);
  white-space: nowrap;
  cursor: pointer;
  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: var(--op-red-idle);
  transition:
    color var(--op-dur-fast) linear,
    transform 120ms var(--op-ease);
}

/* The type is `.op-label` on the element. What is left here is this
   surface's own: the field name yields to the cell beside it. */
.label {
  flex: 0 1 auto;
}

/* Zero flex-basis so a long typed line scrolls the cell instead of truncating the
   label: the field's own name is the last thing a player should lose. */
.cell {
  flex: 1 1 0;
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: var(--op-space-3);
  min-width: 0;
}

/* --- THE TYPED LINE -------------------------------------------------------
   The one input in the runtime. It is a LINE, not a box: a filled entry would be
   the only fill on the surface and it would be the largest one. What says "you are
   typing here" is the rule under the text and the caret on it, and both of those
   light when Lua says this field has the cursor. */
.entry {
  flex: 0 1 auto;
  width: calc(var(--chars, 1) * (1ch + var(--op-track-label)) + 2px);
  max-width: 100%;
  padding: 0 0 2px;
  background: none;
  border: 0;
  border-bottom: 1px solid var(--op-red-idle);
  border-radius: 0;
  outline: none;
  font: 400 var(--op-fs-meta) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: inherit;
  /* THE ONE FILL LEFT, one pixel wide. Left to the browser and simply coloured: a
     caret is the only blink this design allows, and it is allowed because it is the
     player's own position and not the surface talking. */
  caret-color: var(--op-red);
  /* The only place on any surface where a caret and a text selection belong. */
  user-select: text;
  /* The field under the pointer asks for `pointer` and `cursor` inherits; a line
     being typed into is the one child that must not. */
  cursor: text;
  transition: border-color var(--op-dur-fast) linear;
}

/* A selection is a fill, and this is the one the player made themselves. It takes
   the denser rung so it never out-reads the focused frame around it. */
.entry::selection {
  color: var(--op-text);
  background: var(--op-red-deep);
}

.entry::placeholder {
  color: var(--op-text-faint);
  font-style: italic;
  opacity: 1;
}

/* A choice's option and a slider's number, as Lua rendered them, suffix and all. */
.value {
  flex: 0 1 auto;
  opacity: 0.88;
}

/* A RULE, NOT A GAUGE, and ahead of the number as input.css had it. Two pixels
   carrying no text, so they carry no text-shadow either: the tight dark pass is a
   box-shadow instead, which is `InventoryView.vue`'s load rule exactly. */
.rule {
  order: -1;
  flex: none;
  width: 48px;
  height: 2px;
  background: rgba(var(--op-red-idle-rgb), 0.22);
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.95);
}

.rule i {
  display: block;
  height: 100%;
  background: var(--op-red-idle);
  transition: width var(--op-dur-fast) linear;
}

/* `12/24`, and only under the field being typed into. It is the buffer Lua sent,
   counted the way Lua counts it. */
.count {
  flex: none;
  font: 400 var(--op-fs-micro) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  opacity: 0.72;
  font-variant-numeric: tabular-nums;
}

.count.quiet {
  visibility: hidden;
}

.marks {
  flex: none;
  display: flex;
  gap: 2px;
}

/* The affordance column, always last so every mark lands at the same x. */
.mark {
  padding: 0 2px;
  font: 700 var(--op-fs-meta) / 1 var(--op-font-mono);
  color: inherit;
  background: none;
  border: 0;
  cursor: pointer;
}

/* --- HOVER: denser red, no bloom -------------------------------------------
   Weaker than the focused state, deliberately: this is only the field the pointer
   is over, and Lua decides what landing there means. */
.field:hover:not(.on) {
  color: var(--op-red-deep);
  --aug-border-bg: var(--op-red-deep);
  /* The menu's hover weight, as every hover on the surface now is. */
  --aug-border-all: 1.5px;
}

.field:hover:not(.on) .entry {
  border-bottom-color: var(--op-red-deep);
}

/* --- FOCUSED: lit, blooming, and one step out of the column -----------------
   No fill. The frame goes to full red at a heavier stroke, the text lights, the
   rule under the typed line lights with it, and the field steps across by `--pop`.
   The bloom is a `box-shadow` and not a `filter`: a filter would give the one field
   the player is actually reading its own backing store. */
.field.on {
  color: var(--op-red);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2.4px;
  transform: translate3d(var(--pop, 10px), 0, 0);
  box-shadow: 0 0 18px -4px var(--op-red-glow);
  cursor: default;
}

.field.on .label {
  letter-spacing: 0.055em;
  text-shadow: 0 0 10px var(--op-red-glow);
}

.field.on .entry {
  border-bottom-color: var(--op-red);
}

.field.on .rule i {
  background: var(--op-red);
}

/* =============================================================================
   THE FOOT -- what the keys do, and what Lua makes of the answer so far.
   ========================================================================== */
.foot {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-2);
  min-width: 0;
  padding: var(--op-space-3) calc(var(--op-space-3) + var(--op-cut-lg))
    calc(var(--op-space-3) + var(--op-cut-lg)) calc(var(--op-space-3) + var(--op-rule));
  border-top: 1px solid var(--op-red-idle);
}

/* The one place the surface wraps: a hint is a sentence. */
.hint {
  margin: 0;
  color: var(--op-text-dim);
  white-space: normal;
}

/* Lua's reading of the answer so far. At rest it is the surface's own resting red;
   a REFUSAL takes the alarm rung and the weight, not a second hue -- the same call
   `TargetView.vue` makes for a pick that failed. */
.status {
  margin: 0;
  font: 600 var(--op-fs-meta) / 1.4 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: var(--op-red-idle);
  white-space: normal;
}

.status.bad {
  color: var(--op-alarm);
  font-weight: 700;
}

.keys {
  display: flex;
  flex-wrap: wrap;
  /* Wider across than down: the gap between two hints has to out-read the gap
     between a cap and the words that belong to it. */
  gap: var(--op-space-2) var(--op-space-5);
}

.key {
  display: inline-flex;
  align-items: center;
  gap: var(--op-space-2);
}

/* THE ONE DRAWN EDGE LEFT IN THE FOOTER. A keycap depicts a physical key, so it
   keeps the house frame at cap size while everything around it loses its box. No
   fill and no weighted base: `OpKeyCap` built its whole idiom on `inset 0 -2px`
   going to `-4px` on a hold, and a 2px bottom rule is a fill. */
.cap {
  flex: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  box-sizing: border-box;
  min-width: 24px;
  height: 22px;
  padding: 0 7px;
  /* The chamfer lives in the top-right corner, so the right side pays for it. */
  padding-right: calc(7px + var(--op-cut-sm));
  font: 700 var(--op-fs-meta) / 1 var(--op-font-mono);
  letter-spacing: 0.04em;
  color: var(--op-red);
  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 1.8px;
}

/* What the key does. The red is spent on the cap, which is the part that is an
   instrument; the words carry no state and are legibility only. */
.cap-label {
  font: 400 var(--op-fs-micro) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  text-transform: uppercase;
  color: var(--op-text-dim);
}

/* =============================================================================
   THE BOOT-IN -- a stutter, not a fade. One shot, and only on elements the keyed
   v-for has just created: a field that survived the last frame does not re-run it,
   which matters more here than anywhere -- every keystroke brings a new frame, and
   a line that re-animated under the caret would be unusable. Both keyframes touch
   `opacity` and `transform` only, which the compositor can run without a repaint.
   ========================================================================== */
@keyframes field-in {
  0% {
    opacity: 0;
    transform: translate3d(calc(var(--pop, 10px) * -1), 0, 0);
  }

  55% {
    opacity: 1;
    transform: translate3d(2px, 0, 0);
  }

  100% {
    opacity: 1;
    transform: translate3d(0, 0, 0);
  }
}

/* ON THE ROW, NOT THE FIELD. It ran on `.field`, with `.field.on` swapping in a
   second keyframe that ended on the `--pop` step -- so every Up/Down, which moves
   `on` from one field to another, changed BOTH fields' animation-name, and a changed
   name restarts an animation: the two rows blanked (backwards fill, 40ms delay) and
   stuttered in again under the player's caret. The `<li>` never changes class, so
   its animation runs once, when the keyed v-for creates it. The chosen field's step
   is its own `transform` inside the row, and the two compose to exactly the old
   `field-in-on` path (0 -> pop+2px -> pop). SpawnView made the same move. */
.room.open .slot {
  animation: field-in var(--op-enter-ms) var(--op-stutter) backwards;
  /* NO STAGGER, on the owner's word: rows land together, as the menu's buttons and
     the eye's rows do. A per-row delay read as the rows trickling in. */
  animation-delay: 40ms;
}
</style>
