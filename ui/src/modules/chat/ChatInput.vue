<script setup lang="ts">
import { computed, nextTick, onUnmounted, onMounted, ref } from 'vue'
import { emit } from '@/bridge/channel'
import { report } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { list, num, table, text, own } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'
import { inputDrop, setFieldHeight, setInputHeight, setInputOpen } from './state'

/**
 * THE CHAT INPUT LINE -- the modal half of the box.
 *
 * One <input>, a completion list, and the keyboard. The log is `ChatLog.vue` on the
 * overlay layer and never sees any of this.
 *
 * WHAT LEAVES HERE IS A CANDIDATE, NOT A DECISION. `submit` carries the typed line
 * and Lua decides what it is: a message, a command, or a line it refuses to tokenise.
 * This file knows exactly one thing about the difference -- a line starting with `/`
 * gets the completion list -- and nothing about commands, permissions or arguments.
 *
 * FOCUS IS TAKEN ON `focus`, NOT ON `open`. Lua publishes the two in that order and
 * the order is load-bearing: the element focus has to land in a surface that already
 * holds the keyboard, or the caret goes nowhere and the player types into the game.
 *
 * Escape is handled by the focus stack rather than by a key listener here, so that a
 * box opened over something else gives focus back to that something and not to
 * nobody.
 */

interface Suggestion {
  name: string
  help: string
  params: string[]
}

const ANCHORS: Record<string, string> = {
  'bottom-left': 'anchor-bottom-left',
  'bottom-center': 'anchor-bottom-center',
  'top-left': 'anchor-top-left',
  'top-center': 'anchor-top-center'
}

const { t } = useLocale()

const open = ref(false)
const draft = ref('')
const maxLength = ref(240)
const placeholder = ref('')
const anchor = ref('anchor-bottom-left')
const offset = ref(155)
const width = ref(620)

const suggestions = ref<Suggestion[]>([])

/**
 * WHAT THE PLAYER HAS ALREADY SENT, newest last, and where they are in it.
 *
 * This is the terminal's history and not the log's: it holds the lines THIS
 * player typed, including the ones the server refused, because the reason to
 * walk back to a line is almost always to fix it and send it again.
 *
 * `cursor` is an index into it while browsing and `-1` when not. `stash` holds
 * the line that was being composed when browsing started, so walking forward
 * past the newest entry gives it back rather than emptying the box.
 */
const sent = ref<string[]>([])
const cursor = ref(-1)
let stash = ''

/** Entries kept. Older ones fall off, exactly as the log's lines do. */
const HISTORY_CAP = 50

const box = ref<HTMLElement | null>(null)
const row = ref<HTMLElement | null>(null)
const field = ref<HTMLInputElement | null>(null)
let release: (() => void) | null = null
let caretTimer: ReturnType<typeof setInterval> | null = null
let sizer: ResizeObserver | null = null

/**
 * Whether the temporary probe in `show()` has already fired.
 *
 * ONCE PER PAGE LOAD, and that is not thrift. The diagnostic relay is capped --
 * twenty reports on the client, twenty per minute per player on the server -- and
 * those caps exist so a throwing render loop cannot flood the journal. A probe
 * that reports on every open spends that budget on a measurement, and the next
 * REAL failure on this page, in any module, is dropped instead of written down.
 */
let probed = false

function stopClaiming(): void {
  if (caretTimer === null) return
  clearInterval(caretTimer)
  caretTimer = null
}

/**
 * KEEPS ASKING FOR THE CARET UNTIL THE ELEMENT ACTUALLY HAS IT.
 *
 * One `focus()` after `nextTick` is not enough, and the reason is a race across
 * two processes. Lua publishes `focus` and then `open` in the same burst, so the
 * page handles both synchronously -- but taking the keyboard is not something the
 * page can do: `acquireFocus` only ANNOUNCES the intent on `opx:focus:set`, Lua
 * answers it a frame or more later by calling `OPX.Surface.Focus`, and only then
 * does CEF hand this page the keyboard. A `focus()` issued before that lands on
 * an element in a page the host has not focused yet, and is dropped or undone the
 * moment the host does focus it.
 *
 * So the claim is retried until `document.activeElement` agrees, and given up on
 * after a second rather than spinning: a box the player cannot type into is a bug
 * worth a few wasted timer ticks, and a timer that never stops is a worse one.
 */
function claimCaret(): void {
  stopClaiming()
  let tries = 0
  const attempt = (): void => {
    const element = field.value
    if (element === null || document.activeElement === element) {
      stopClaiming()
      return
    }
    element.focus()
    tries += 1
    if (tries >= 20) stopClaiming()
  }
  void nextTick(attempt)
  caretTimer = setInterval(attempt, 50)
}

/**
 * The command being typed: its name so far, and whether the player has moved past
 * it onto the arguments. Null when the line is a message and not a command.
 */
const command = computed(() => {
  if (draft.value.charAt(0) !== '/') return null
  const rest = draft.value.slice(1)
  const space = rest.indexOf(' ')
  return {
    name: (space === -1 ? rest : rest.slice(0, space)).toLowerCase(),
    onArgs: space !== -1
  }
})

/**
 * TWO MODES, AND THE SECOND ONE IS THE POINT.
 *
 * While the NAME is being typed this is a list to choose from. The moment a space
 * is typed the name is settled, and the list stops being a choice and becomes the
 * ONE signature the player is now filling in -- which is exactly when the
 * parameters matter and exactly when the first version of this file threw them
 * away. A completion list that vanishes the instant you need the arguments is a
 * completion list that is never there when it counts.
 */
const matches = computed(() => {
  const typed = command.value
  // ONLY A COMMAND GETS A LIST. An empty line used to offer the first eight
  // commands as a teaser, and the box opens empty -- so every open began with a
  // menu covering the log the player had just pressed the key to read. A list is
  // shown when it is being used, which is from the `/` onwards.
  if (typed === null) return []
  if (typed.onArgs) {
    const exact = suggestions.value.find((entry) => entry.name.toLowerCase() === typed.name)
    return exact ? [exact] : []
  }
  return suggestions.value
    .filter((entry) => entry.name.toLowerCase().indexOf(typed.name) === 0)
    .slice(0, 8)
})

/** Whether what is on screen is a signature being filled rather than a choice. */
const signature = computed(() => command.value?.onArgs === true && matches.value.length === 1)

/**
 * Which parameter the caret is in, or -1. Counted from the tokens after the name,
 * so the one being typed -- including an empty one straight after the space -- is
 * the one highlighted.
 */
const argIndex = computed(() => {
  const typed = command.value
  if (typed === null || !typed.onArgs) return -1
  const rest = draft.value.slice(1)
  return rest.slice(rest.indexOf(' ') + 1).split(/\s+/).length - 1
})

/** Whether the length budget has started to bind. See the template. */
const crowded = computed(() => draft.value.length >= maxLength.value * 0.8)

function reset(): void {
  draft.value = ''
  cursor.value = -1
  stash = ''
}

function holdFocus(hold: boolean): void {
  if (hold) {
    if (release !== null) return
    release = acquireFocus({
      id: 'chat',
      // Escape asks Lua to close. It is not closed here: Lua hands the keyboard
      // back first and then tells the view, and a view that closed itself would
      // paint the close before the keyboard had gone anywhere.
      onEscape: () => emit('opx:chat:close', {})
    })
    return
  }
  if (release === null) return
  release()
  release = null
}

/**
 * TELLS THE LOG HOW MUCH ROOM THIS BLOCK IS TAKING.
 *
 * The log draws on the other layer and cannot see this one, so it left a fixed
 * clearance -- one field row -- and the completion list, which is up to eight
 * rows and appears a keystroke at a time, grew straight over it. What the log
 * needs is not a constant but this box's height as it is now, which is what the
 * observer below reports on every change.
 */
function measure(): void {
  const element = box.value
  setInputHeight(element === null ? 0 : Math.round(element.getBoundingClientRect().height))
  // The field row on its own, which is what decides how far the block drops clear of
  // the log (`inputDrop` in state.ts). Measured in the same task the box opens in,
  // before the first paint, so the block is never drawn at the old line first.
  setFieldHeight(row.value === null ? 0 : Math.round(row.value.getBoundingClientRect().height))
}

function startSizing(): void {
  void nextTick(() => {
    const element = box.value
    if (element === null) return
    measure()
    if (typeof ResizeObserver === 'undefined') return
    // A second `open` while the box is up would otherwise orphan the first observer,
    // still firing `measure` for the rest of the session.
    if (sizer !== null) sizer.disconnect()
    sizer = new ResizeObserver(measure)
    sizer.observe(element)
  })
}

function stopSizing(): void {
  if (sizer !== null) sizer.disconnect()
  sizer = null
  setInputHeight(0)
  setFieldHeight(0)
}

function show(): void {
  open.value = true
  setInputOpen(true)
  reset()
  claimCaret()
  startSizing()

  // TEMPORARY INSTRUMENT. It is what found the two faults this file and its Lua
  // half were carrying -- the config never arriving, so the box drew itself at
  // the page's own defaults, and the completion list never arriving with it --
  // and it stays until a session confirms both are gone. It reaches the server
  // log through `opx:diag` and the diagnostics relay.
  //
  // A QUARTER OF A SECOND, not `nextTick`. Lua publishes `open` and then the
  // completion list, as separate messages the page handles in separate tasks; a
  // microtask reads the page BEFORE the second one lands and reports zero
  // whatever the truth is. That is what the first version of this probe did, and
  // it is why the list looked empty when it was merely late.
  if (probed) return
  probed = true
  window.setTimeout(() => {
    const placed = box.value ? getComputedStyle(box.value) : null
    report(
      `anchor=${anchor.value} held=${suggestions.value.length} shown=${matches.value.length}` +
        ` offset=${offset.value} pos=${placed?.position ?? '?'}` +
        ` left=${placed?.left ?? '?'} top=${placed?.top ?? '?'}`,
      'chat-input state'
    )
  }, 250)
}

function hide(): void {
  open.value = false
  setInputOpen(false)
  stopClaiming()
  stopSizing()
  reset()
}

/**
 * Replaces the typed command name with the closest one, ready for arguments.
 *
 * THE CLOSEST ONE IS THE FIRST ROW, always. The list used to be walkable and Tab
 * took whichever row was under the selection; the arrows are the history's now,
 * so there is nothing left to move the selection with and a completion is what
 * the prefix already says it is.
 */
function complete(): void {
  const entry = matches.value[0]
  if (!entry) return
  draft.value = `/${entry.name} `
  void nextTick(() => caretToEnd())
}

/** Puts the caret after the last character, which `focus()` alone does not. */
function caretToEnd(): void {
  const element = field.value
  if (element === null) return
  element.focus()
  const at = element.value.length
  element.setSelectionRange(at, at)
}

/**
 * WALKS WHAT THIS PLAYER HAS SENT. `-1` is back into the older lines, `+1` is
 * forward towards the newest.
 *
 * Forward past the newest entry is not a stop: it restores the line that was
 * being composed when browsing started, so a player who looked back at one thing
 * and changed their mind gets their own half-finished sentence returned rather
 * than an empty box.
 */
function recall(direction: number): void {
  const count = sent.value.length
  if (count === 0) return

  // Not browsing yet: -1 enters at the newest entry, +1 has nowhere to go.
  if (cursor.value === -1) {
    if (direction > 0) return
    stash = draft.value
    cursor.value = count - 1
  } else {
    const next = cursor.value + (direction < 0 ? -1 : 1)
    if (next < 0) return // Already at the oldest; stay there rather than wrap.
    if (next >= count) {
      cursor.value = -1
      draft.value = stash
      stash = ''
      void nextTick(() => caretToEnd())
      return
    }
    cursor.value = next
  }

  draft.value = sent.value[cursor.value] ?? ''
  void nextTick(() => caretToEnd())
}

/** Keeps one sent line, newest last. */
function remember(line: string): void {
  if (line === '') return
  // A line sent twice in a row is one entry: the second copy would only make the
  // player press the arrow twice to reach what is behind it.
  if (sent.value[sent.value.length - 1] !== line) sent.value.push(line)
  if (sent.value.length > HISTORY_CAP) {
    sent.value.splice(0, sent.value.length - HISTORY_CAP)
  }
}

/**
 * Any edit ends the browse. The recalled line becomes the player's own draft the
 * moment they change a character of it, so the next arrow starts again from the
 * newest entry instead of from wherever the walk had reached.
 */
function onInput(): void {
  if (cursor.value === -1) return
  cursor.value = -1
  stash = ''
}

function onKeyDown(event: KeyboardEvent): void {
  if (event.key === 'Enter') {
    event.preventDefault()
    remember(draft.value)
    emit('opx:chat:submit', { text: draft.value })
    return
  }
  if (event.key === 'Tab') {
    // A settled name has nothing left to complete, and re-completing it would
    // wipe the arguments already typed.
    if (signature.value) return
    event.preventDefault()
    complete()
    return
  }
  if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
    // THE ARROWS ARE THE HISTORY'S, whatever is on screen. They used to walk the
    // completion list, which is the one thing a player never needs them for --
    // the list is a prefix search and Tab takes it -- and it cost them the
    // gesture every command line has had for forty years. The list is not
    // selectable any more; the caret does not move in a one-line field either,
    // so nothing else wants these two keys.
    event.preventDefault()
    recall(event.key === 'ArrowUp' ? -1 : 1)
  }
}

/**
 * A parameter, as the dispatcher describes it.
 *
 * `OPX.Command.Suggestions` sends `entry.params` straight through, and a command
 * registers them as TABLES -- `{ name = 'key', optional = true, help = '...' }` --
 * not as strings. Read as strings they all came back empty, which is why the
 * signature row drew a command name and then nothing at all.
 *
 * The brackets are the convention every command line uses: angle for what must be
 * given, square for what may be left out.
 */
function paramLabel(value: unknown): string {
  const entry = table(value)
  const name = text(entry.name)
  if (name === '') return ''
  return entry.optional === true ? `[${name}]` : `<${name}>`
}

function paramsOf(value: unknown): string[] {
  return list<unknown>(value)
    .map(paramLabel)
    .filter((label) => label !== '')
}

/** Adds or replaces one entry, keyed on its name. */
function upsert(payload: Payload): void {
  const entry = table(payload.suggestion)
  const name = text(entry.name)
  if (name === '') return

  const row: Suggestion = {
    name,
    help: text(entry.help),
    params: paramsOf(entry.params)
  }
  const at = suggestions.value.findIndex((existing) => existing.name === name)
  if (at === -1) suggestions.value.push(row)
  else suggestions.value[at] = row
}

/**
 * Takes one payload of the completion list.
 *
 * THE LIST ARRIVES IN PIECES. `WebUI.Page.send` bounds what it will carry and
 * REFUSES what is over rather than truncating it, and the whole list -- every
 * command a player may be shown, each with its help string and its parameters --
 * is the one payload on this seam that grows with the runtime. So Lua cuts it
 * into payloads of eight and marks the first `reset`: that one replaces what is
 * held, the rest are appended to it.
 *
 * `reset` missing counts as true, so a single whole list still behaves as one.
 */
function replaceAll(payload: Payload): void {
  const rows: Suggestion[] = list<unknown>(payload.suggestions)
    .map((value) => {
      const entry = table(value)
      return {
        name: text(entry.name),
        help: text(entry.help),
        params: paramsOf(entry.params)
      }
    })
    .filter((entry) => entry.name !== '')

  if (payload.reset === false) {
    for (const row of rows) {
      const at = suggestions.value.findIndex((existing) => existing.name === row.name)
      if (at === -1) suggestions.value.push(row)
      else suggestions.value[at] = row
    }
  } else {
    suggestions.value = rows
  }
}

useBridge('opx:chat:view', (payload: Payload) => {
  // Every payload names its layer, and the log's are not ours.
  if (text(payload.surface) !== 'interactive') return

  switch (text(payload.kind)) {
    case 'config':
      maxLength.value = num(payload.maxLength, 240)
      placeholder.value = text(payload.placeholder)
      anchor.value = own(ANCHORS, text(payload.anchor)) ?? 'anchor-bottom-left'
      offset.value = num(payload.offset, 155)
      width.value = num(payload.width, 620)
      break
    case 'focus':
      holdFocus(payload.hold === true)
      break
    case 'open':
      show()
      break
    case 'close':
      hide()
      break
    case 'suggest':
      upsert(payload)
      break
    case 'unsuggest': {
      const name = text(payload.name)
      suggestions.value = suggestions.value.filter((entry) => entry.name !== name)
      break
    }
    case 'suggestions':
      replaceAll(payload)
      break
  }
})

onMounted(() => {
  // The signal Lua waits for. Until a layer reports ready nothing is published to
  // it, and `openChat` refuses outright rather than taking the keyboard with
  // nowhere to type.
  emit('opx:chat:ready', { surface: 'interactive' })
})

onUnmounted(() => {
  // A focus held across an unmount leaves the player unable to move.
  holdFocus(false)
  stopClaiming()
  stopSizing()
  setInputOpen(false)
})
</script>

<template>
  <div
    v-if="open"
    ref="box"
    class="chat-input"
    :class="anchor"
    :style="{ '--chat-offset': `${offset}px`, '--chat-width': `${width}px`, '--chat-drop': `${inputDrop}px` }"
  >
    <ul
      v-if="matches.length > 0"
      class="chat-suggestions"
      :class="{ 'is-signature': signature }"
      data-augmented-ui="tr-clip border"
    >
      <li
        v-for="(entry, index) in matches"
        :key="entry.name"
        class="chat-suggestion"
        :class="{ 'is-selected': !signature && index === 0 }"
      >
        <span class="chat-suggestion-name">/{{ entry.name }}</span>
        <!-- Each parameter is its own span so the one the caret is in can be lit.
             Joined into a single string it was decoration; split, it is the only
             thing on screen telling the player which argument they are filling. -->
        <span v-if="entry.params.length > 0" class="chat-suggestion-params">
          <span
            v-for="(param, at) in entry.params"
            :key="param + at"
            class="chat-param"
            :class="{ 'is-here': signature && at === argIndex }"
          >{{ param }}</span>
        </span>
        <span v-if="entry.help" class="chat-suggestion-help op-truncate">{{ entry.help }}</span>
      </li>
    </ul>

    <!-- ONE ROW. The caps were a second row under the box and the count was
         always on; both are bookkeeping, and bookkeeping does not get its own
         line on a surface whose whole job is one sentence. The caps are local
         rather than `OpKeyCap` because that component fills its plate with
         `--op77-accent`, which pass 02 forbids and `.op-theme-city` turns
         yellow; every pass-02 surface draws its own for the same reason. -->
    <!-- NO `.op-lift`. It used to be here, unconditionally, and this is the one
         box in the runtime that is TYPED INTO: `shapes.css` says of `.op-lift`
         that "IT IS A FILTER ... never put it on anything whose value changes
         every frame", and the value inside this box changes on every keystroke
         and again on every caret blink, each one re-rasterising the filter's
         whole backing store. Every other `.op-lift` in the tree is bound to a
         state over static content -- the chosen row, the failed toast -- and
         this was the only unconditional one. The two files that hit the same
         wall took the same way out: `HudVoice.vue` ("THE BLOOM IS NOT THE
         ANSWER") and `DownedView.vue` ("NO FILTER, ANYWHERE"). The frame, the
         arete and the 2px border are what say this box is live. -->
    <!-- NOT `.op-frame`, though it is drawn like one: that preset carries the house
         hover, and the field is under the cursor for as long as the chat is open --
         a pointer resting on it dropped the lit 2px arete to the 1.5px hover frame.
         The cut and the type colour it gave are restated below. -->
    <div ref="row" class="chat-field op-arete" data-augmented-ui="tr-clip border">
      <span class="chat-caret" aria-hidden="true">&gt;</span>
      <input
        ref="field"
        v-model="draft"
        type="text"
        class="chat-entry"
        :maxlength="maxLength"
        :placeholder="placeholder"
        autocomplete="off"
        spellcheck="false"
        @input="onInput"
        @keydown="onKeyDown"
      />
      <!-- Only once it is nearly spent, and then as what is LEFT rather than as
           `212/240`: a budget is read when it starts to bind, not before. -->
      <span v-if="crowded" class="chat-count">{{ maxLength - draft.length }}</span>
      <span class="chat-hints">
        <kbd v-if="matches.length > 0" class="cap op-cap" data-augmented-ui="tr-clip border">{{ t('chat.key.tab') }}</kbd>
        <kbd class="cap op-cap" data-augmented-ui="tr-clip border">{{ t('chat.key.enter') }}</kbd>
        <kbd class="cap op-cap" data-augmented-ui="tr-clip border">{{ t('chat.key.escape') }}</kbd>
      </span>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   DESIGN PASS 02 -- RED AND OUTLINED. The input line's half of it.

   Unlike the log, this half IS a cluster: it encloses something, it takes the
   keyboard, and it is the only part of the chat a player drives. So it takes the
   menu's half of the pass rather than the HUD's -- a 9-slice frame and the lit
   rung while it holds focus.

   NOT TILTED, AND THAT IS THE ONE PLACE THIS FILE LEAVES THE PASS. The name of
   the pass says TILTED and every other surface obeys it; this one does not,
   because it is the surface the player TYPES INTO. A `rotateY` resamples every
   glyph the caret sits between, and a line being composed has to be the sharpest
   text on screen rather than the most styled. The precedent is already in the
   tree: `FormView.vue` and `InventoryView.vue` both take `--tilt: 0deg` for the
   neighbouring reason, and the first version of this file leaned at 7deg and was
   rejected on sight.

   THE FRAME IS AUGMENTED-UI, like every other frame in the runtime. The field,
   the suggestion list and the three keycaps are one attribute each; the state
   is `--aug-border-bg`, and the geometry never distorts with the element's
   width, which matters here because the box is as wide as the operator
   configured it.
   ========================================================================== */

.chat-input {
  position: absolute;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-2);
  width: var(--chat-width);
  max-width: calc(100vw - var(--op-inset-x) * 2);

  /* NO PERSPECTIVE, AND NO TILT ON ANYTHING BELOW. Pass 02 leans a surface about
     the screen edge it is anchored to, and that is right for a HUD cluster read
     at a glance from the corner of the eye. It is wrong for the one surface on
     this page that is TYPED INTO: a `rotateY` resamples every glyph the caret
     sits between, and a line the player is composing has to be the sharpest text
     on screen, not the most styled. `FormView.vue` and `InventoryView.vue` both
     take `--tilt: 0deg` for the neighbouring reason, and this is the same call.  */

  text-shadow:
    0 1px 0 rgba(0, 0, 0, 0.92),
    0 0 6px rgba(0, 0, 0, 0.65);
}

/* `--chat-drop` is how far the field row overruns the room the log leaves for it
   (see `inputDrop` in state.ts): the input hangs that much lower so the log does
   not have to move when the box opens (#120). Only bottom anchors take it. */
.anchor-bottom-left {
  left: var(--op-inset-x);
  bottom: calc(var(--chat-offset) - var(--op-space-6) - var(--chat-drop, 0px));
}

/* Centred on the screen's axis rather than pinned to the left inset, so the box
   sits clear of the vitals in the corner and under whatever modal is open. The
   width is the operator's, so the shift is half of it and not a fixed number. */
.anchor-bottom-center {
  left: 50%;
  transform: translateX(-50%);
  bottom: calc(var(--chat-offset) - var(--op-space-6) - var(--chat-drop, 0px));
}

/* AT THE TOP THE INPUT LINE SITS ON THE OFFSET ITSELF and the log is pushed
   below it -- the mirror of the bottom anchors, where the log is above and the
   input hangs under it. Written out because the naive mirror (input at
   `offset - space-6`, log at `offset`) puts a 40px-tall row at 16px and the log
   at 48px, and the two overlap. */
.anchor-top-left {
  left: var(--op-inset-x);
  top: var(--chat-offset);
}

.anchor-top-center {
  left: 50%;
  transform: translateX(-50%);
  top: var(--chat-offset);
}

/* THE LIST FLIPS WITH THE ANCHOR. The completion list is written before the field
   in the template because at the bottom of the screen it belongs above it -- a
   list that grew downward off the bottom edge would be unreadable. Anchored at
   the TOP the same list must grow downward instead, and `column-reverse` says
   that in one property without the template having to know where it is. */
.anchor-top-left,
.anchor-top-center {
  flex-direction: column-reverse;
}

/* The frame, and the only thing on this surface that is lit: the box is only ever
   on screen while it holds the keyboard, so there is no idle rung to draw. The
   tilt hinges on the left edge because both anchors this view accepts are on the
   left, and it leans away from the player's reading edge rather than into it. */
.chat-field {
  /* The arete below is absolute against this box. */
  position: relative;
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  padding: var(--op-space-2) var(--op-space-3);

  /* 0.92 AND NOT THE HOUSE 0.78. This is the only box in the runtime that is
     TYPED INTO, and the owner still read it as unbacked at plate strength -- a
     line being composed sits under the caret, is re-read letter by letter, and
     the street behind it is moving. It is the one surface where the ground is
     worth more than the openness. */
  background: rgba(var(--op-plate-rgb), 0.92);
  color: var(--op-red-text);
  --aug-tr: var(--op-cut-sm);
  --aug-border-all: 2px;
}

.chat-caret {
  font-family: var(--op-font-mono);
  font-size: var(--op-fs-body);
  color: var(--op-red);
}

.chat-entry {
  flex: 1;
  min-width: 0;
  margin: 0;
  padding: 0;
  border: 0;
  background: transparent;
  outline: none;

  font-family: var(--op-font-body);
  font-size: var(--op-fs-body);
  color: var(--op-red-text);
  /* The native caret takes the colour of the text unless told otherwise, and a
     white bar in a red line is the one pixel that would not belong. */
  caret-color: var(--op-red);
}

.chat-entry::placeholder {
  color: var(--op-red-idle);
  opacity: 0.7;
}

.chat-count {
  font-family: var(--op-font-mono);
  font-size: var(--op-fs-label);
  letter-spacing: var(--op-track-label);
  color: var(--op-red-idle);
}

/* The list leans with the field rather than standing square behind it: one plane,
   or the two read as two surfaces that happen to be stacked. */
.chat-suggestions {
  display: flex;
  flex-direction: column;
  margin: 0;
  padding: var(--op-space-1) 0;
  list-style: none;

  /* THE GROUND FOLLOWS THE CUT. A plain `background` fills the BORDER BOX and
     would square the chamfer back up; augmented-ui clips the element, so the
     ground is the cut shape and nothing has to be painted into a sprite. */
  background: var(--op-plate);
  /* What `.op-frame` gave it, without the hover: a list of completions is not
     pressed, so it does not light under the pointer as a button would. */
  color: var(--op-red-text);
  --aug-tr: var(--op-cut-sm);
}

/* Nothing is filled, so the marked row is marked by its leading rule going lit
   and its lettering with it -- the menu's chosen-row language at one rung down,
   because a completion is a candidate and not a choice yet.

   IT IS ALWAYS THE FIRST ROW: the mark says what Tab would take, not where a
   selection has been moved to. The arrows stopped moving it when they became the
   history's. */
.chat-suggestion {
  display: flex;
  align-items: baseline;
  gap: var(--op-space-2);
  padding: var(--op-space-1) var(--op-space-3);
  border-left: 2px solid transparent;
}

.chat-suggestion.is-selected {
  border-left-color: var(--op-red);
}

.chat-suggestion-name {
  font-family: var(--op-font-mono);
  font-size: var(--op-fs-meta);
  color: var(--op-red-idle);
}

.chat-suggestion.is-selected .chat-suggestion-name {
  color: var(--op-red);
}

.chat-suggestion-params {
  display: inline-flex;
  gap: var(--op-space-2);

  font-family: var(--op-font-mono);
  font-size: var(--op-fs-label);
  color: var(--op-text-dim);
}

/* The argument the caret is in. Lit and underscored rather than filled: on this
   surface a fill would be the only one, and an underscore is what a form field
   looks like in a monospace line anyway. */
.chat-param.is-here {
  color: var(--op-red);
  border-bottom: 1px solid var(--op-red);
}

/* A signature is a readout, not a menu: nothing in it is selectable, so the
   leading rule that marks a choice is withheld. */
.chat-suggestions.is-signature .chat-suggestion {
  border-left-color: transparent;
}

.chat-suggestion-help {
  flex: 1;
  font-family: var(--op-font-body);
  font-size: var(--op-fs-meta);
  color: var(--op-text-faint);
  text-align: right;
}

/* Inside the field row now, hard right, and wordless. Enter and Escape in a text
   box need no caption in any language, and the placeholder already says what the
   box is for -- so the words came off and the row they used to sit on went with
   them. */
.chat-hints {
  display: inline-flex;
  align-items: center;
  gap: var(--op-space-1);
  flex: none;
}

/* A cap is a small frame, and its cut is a token rather than a second sprite. */
.cap {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 18px;
  padding: 1px var(--op-space-1);

  font-family: var(--op-font-mono);
  font-size: var(--op-fs-micro);
  letter-spacing: var(--op-track-micro);
  color: var(--op-red);
}
</style>
