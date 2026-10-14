<script setup lang="ts">
import { computed, nextTick, onUnmounted, ref } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { bool, num, table, text, records } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { glyphPaths } from './glyphs'

/**
 * THE TARGET SURFACE -- port of `opx77_target/web/{index.html,target.css,target.js}`.
 *
 * Hold the key, RIGHT-CLICK what you want, LEFT-CLICK the row. LUA CASTS EVERY RAY
 * AND DECIDES EVERY ROW. This page draws the list and reports two things.
 *
 * THE TWO BUTTONS DO NOT SHARE A JOB, and that separation is the whole gesture:
 *   RIGHT asks. On the world it reports a pick; on a cascade that is already up it
 *         steps one column back; at the root it closes the eye.
 *   LEFT  answers. On a row it runs it, on a folder it opens it, and outside the
 *         list it closes the eye.
 * The one thing that cannot happen any more is the one that used to: a near-miss on
 * a row re-casting the ray at whatever was standing behind the list.
 *
 * WHAT IT REPORTS, and it is intents in the strictest sense this tree has:
 *  - where the pointer is (`hover`) and where the RIGHT button was pressed (`pick`).
 *    The press's own coordinates travel, never the pointer's current ones: Lua casts
 *    the ray at the point the player pressed, and by the time the handler runs the
 *    pointer has already moved.
 *  - which row was clicked (`select`), by token. Nothing else -- not the label, not
 *    what it means, not whether it should have been clickable. Lua re-resolves the
 *    token, re-checks the target and re-asks the row's owner before anything runs.
 *
 * WHAT IT DECIDES FOR ITSELF, and only this, because none of it is a fact about the
 * world: which folders of the group tree are open, and which row has keyboard focus.
 * Every row in the tree was already allowed by Lua before it was sent.
 *
 * THE THREE STATES, all three carried over deliberately:
 *  - LOADING is delayed by `LOADING_DELAY_MS`. A pick that resolves faster than that
 *    never shows a panel at all, which is most of them; without the delay every
 *    pick flashes a spinner.
 *  - EMPTY DRAWS NOTHING. Not an empty panel and not a line saying there is nothing
 *    here: the surface goes back to waiting as if the press had not happened.
 *  - the CASCADE, anchored at the pick point and kept inside the viewport.
 *
 * ── THE CASCADE ──────────────────────────────────────────────────────────────
 *
 * A folder opens on HOVER and its level appears as a NEW COLUMN beside the one it
 * came from. The parent stays on screen with its folder row lit, so the whole trail
 * is visible at once instead of one level at a time.
 *
 * `path` is still the single source of truth -- it is the trail of open folder names
 * -- but it no longer selects ONE level. `columns` derives one level per PREFIX of
 * it, so a path of `['Staff', 'Weather']` is three columns: the root, Staff, and
 * Weather. Nothing about the payload or the channels changed; this is a different
 * projection of the same `group` strings Lua already sends.
 *
 * THE HARD PART IS NOT THE LAYOUT, IT IS THE POINTER. Moving diagonally from a
 * folder row to its child column crosses the parent's OTHER rows, and a naive
 * implementation closes the child before the pointer arrives. See `inCorridor`.
 *
 * ── THE SUBMENU THAT OPENED AND WENT STRAIGHT BACK ───────────────────────────
 *
 * Kept, because the fix below is what makes the paragraph above safe.
 *
 * A folder row opened its level and the list snapped back to the root immediately:
 *
 *   1. `.eye-room` carried the `@click` that reported a pick. That handler is the
 *      CANCEL now and the trap is word for word the same one, so none of this is
 *      only history. The guard against firing it for a click on the list itself was
 *      `listEl.contains(event.target)` -- evaluated in the BUBBLE phase, after the
 *      row's own handler had run.
 *   2. Between two listeners of one dispatch the browser runs a microtask
 *      checkpoint, and Vue's scheduler flushes on a microtask. So the level change
 *      was already painted by the time the click reached `.eye-room`: the clicked
 *      row -- keyed, and gone from the new level -- had been UNMOUNTED.
 *   3. The event path is computed once at dispatch and retained, so `.eye-room`
 *      still ran, now holding an `event.target` that no longer had a parent.
 *      `contains` answered false, and the page reported a fresh pick at the folder
 *      row's coordinates. Lua obliged: `target:loading` resets the trail and
 *      `target:menu` redraws the root. The submenu opened, then went back.
 *
 * The guard is now taken on the CASCADE WRAPPER, which survives every level change
 * there is -- see `onListCapture`. Re-reasoned for hover in `applyPath`.
 *
 * ── DESIGN PASS 02 ──────────────────────────────────────────────────────────
 *
 * THIS SURFACE DRAWS ITS OWN ROWS AND ITS OWN SPINNER, for the same reason
 * `MenuView.vue` does: `OpPanel`, `OpRow` and `OpSpinner` are shared with prompts,
 * panel and the entry form, they are built on augmented-ui, and all three paint
 * `--op77-accent` -- which `.op-theme-city` makes Night City yellow. This pass is
 * red and tilted, so the three go and the row is drawn here.
 *
 * IT DRAWS NO PANEL AT ALL. A column has no enclosure: the rows sit loose on the
 * gameplay plane. See point 3 of the style header for what that cost and what paid
 * for it.
 *
 * Nothing about the protocol changed. Same channels, same payload fields, same
 * handle guard, same focus call.
 */

/** Lua's handle, echoed back untouched. Never coerced -- an integer must stay one. */
type Handle = string | number

interface Row {
  token: string
  label: string
  description: string
  group: string
  icon: string
  danger: boolean
  /** `undefined` means this row has no box at all, not an unchecked one. */
  checked: boolean | undefined
}

/**
 * The four lines Lua sends. TWO OF THEM ARE READ AND NOT DRAWN, and the line between
 * the pairs is what the sentence DOES rather than where it came from: a line that
 * tells the player what to do is gone, a line that reports a state is not.
 *
 * Both are still parsed off the payload and both keep their locale entries, which is
 * this tree's standing pattern for a field a surface has stopped drawing --
 * `payload.eyebrow` in `HudInfo.vue` and `row.hold` in `PromptsRoot.vue` are the
 * other two. Lua's contract does not change because a page changed its mind.
 */
interface Labels {
  /** STATE: a pick is resolving. Drawn, beside the spinner. */
  looking: string
  /** STATE: Lua refused this pick. Drawn, above the rows that are still live. */
  unavailable: string
}

/** One drawn line: an action Lua sent, or a folder standing for the rows below it. */
type Entry =
  | { kind: 'row'; row: Row }
  | { kind: 'folder'; name: string; count: number }

/** One level of the tree, drawn as one column. */
interface Column {
  depth: number
  entries: Entry[]
  /** The folder of THIS column that is open, so it can stay lit while the pointer
      works in the column it opened. '' when this is the deepest column. */
  openName: string
}

/** The pointer's journey from a folder row to the column it opened. */
interface Aim {
  /** Where the pointer was when the column opened: the apex of the corridor. */
  ax: number
  ay: number
  /** The child column's NEAR edge, which is the base of the corridor. */
  nx: number
  top: number
  bottom: number
}

/** A group is a folder path: "Staff/Weather" lists under Staff, then Weather. */
const GROUP_SEPARATOR = '/'

/** A pick that answers faster than this never shows its panel. */
const LOADING_DELAY_MS = 180

/** Half the old reticle: the list still hangs from the click point by this much, so
    the first row lands beside the pointer rather than under it. */
const EYE_HALF = 20

/** The gap the cascade keeps from the click point, and from the screen edge. */
const GAP = 6
const EDGE = 12

/**
 * One column, and the gap between two of them -- "laisse un petit gap entre les
 * deux".
 *
 * RE-JUDGED once the columns lost their outlines. With a frame, the gap only had to
 * be a gap between two drawn edges and 8px did it. With no frame there is no drawn
 * edge at all: the space is the ONLY thing saying where one level ends, so it has to
 * be legible on its own. 16px (`--op-space-4`) is what it is now, and the eye reads
 * more than that -- the rows are inset 12px from each column's box, so the distance
 * between the last row frame of one level and the first of the next is 12 + 16 + 12 =
 * 40px, against a 4px gap between two rows of the SAME level. An order of magnitude
 * between "next row" and "next level" is the separation the outline used to draw.
 *
 * It is still crossed without aiming: 16px of true empty space is one small pointer
 * motion, and it is crossed INSIDE the corridor anyway, so nothing switches under it.
 */
const COLUMN_W = 224
const COLUMN_GAP = 16
const STEP = COLUMN_W + COLUMN_GAP

/**
 * How long a folder must be pointed at before it opens.
 *
 * 110ms, which is the menu surface's debounce for the same gesture. The number is
 * copied rather than tuned: it is the same question asked of the same hand on the
 * same screen, and two surfaces answering it differently is a difference the player
 * would feel as inconsistency rather than as care. Below ~90ms a pointer crossing
 * the list opens folders it merely passed over; above ~150ms the open reads as lag.
 */
const HOVER_INTENT_MS = 110

/**
 * How long the corridor may hold a switch back while the pointer is inside it.
 *
 * The corridor alone would be sticky: a pointer that stops inside it, on a sibling,
 * would never switch. This is the cap. 320ms is longer than a deliberate diagonal
 * takes to cross one column and short enough that a parked pointer gets what it is
 * pointing at within a third of a second.
 */
const AIM_HOLD_MS = 320

/** The corridor's base is the child column's near edge, grown by this much at each
    end: the pointer aiming just over a corner is still aiming at the column. */
const AIM_PAD = 10

const handle = ref<Handle | null>(null)
const open = ref(false)
const busy = ref(false)
const available = ref(false)
const loading = ref(false)
const failed = ref(false)
const rows = ref<Row[]>([])
const path = ref<string[]>([])
const labels = ref<Labels>({ looking: '', unavailable: '' })
const pendingToken = ref('')

/** 0..1 of the viewport: where the pointer is, and where the click that built this
    list was. The cascade stays where the click was. */
const eye = ref({ x: 0.5, y: 0.5 })
const anchor = ref({ x: 0.5, y: 0.5 })

/** The viewport, as a ref so the placement recomputes on a resize. */
const view = ref({ w: window.innerWidth, h: window.innerHeight })

const listEl = ref<HTMLElement | null>(null)
const top = ref(0)
const keyboard = ref(false)

/**
 * Which way the cascade grows: 1 right, -1 left, 0 not yet decided.
 *
 * DECIDED ONCE PER PICK and then kept. A cascade that changed sides halfway down its
 * own trail would move every column already on screen, so the side is chosen from
 * the room beside the click point before the first folder opens -- not re-derived per
 * column, which is the one thing a cascade must never do.
 */
const side = ref(0)

let hoverMs = 90
let hoverTimer: ReturnType<typeof setTimeout> | undefined
let loadingTimer: ReturnType<typeof setTimeout> | undefined
let sentPoint: { x: number; y: number } | null = null
let release: (() => void) | undefined
let frame = 0

/** Where the pointer is in CLIENT pixels. The corridor is screen geometry, so it is
    kept in screen units and not in the 0..1 Lua is told about. */
const pointer = { x: -1, y: -1 }

/** The corridor being honoured, or null when the pointer is not in transit. */
let aim: Aim | null = null

/** The level change the pointer has asked for and not yet been given. */
let intent: { next: string[]; el: HTMLElement } | null = null
let intentTimer: ReturnType<typeof setTimeout> | undefined

/** Whether a mouse button is down. A level must not change between a press and its
    release: the click's target is hit-tested at RELEASE, so a row that arrived in
    between would take a click the player aimed at something else. */
let pressed = false

/**
 * Where the RIGHT button went down, or null.
 *
 * `contextmenu` is dispatched on the RELEASE of the right button, not on its
 * press -- so `event.clientX` on that handler is where the pointer ENDED UP. A
 * press-and-drag of a few pixels is an ordinary thing a hand does, and this whole
 * surface is built on the rule that the ray is cast where the player aimed and
 * not where the pointer has since gone. So the press point is latched here, in
 * the capture phase on `window`, and the release only decides WHETHER to send it.
 */
let pressPoint: { x: number; y: number } | null = null

/**
 * The `timeStamp` of the click the cascade has already consumed.
 *
 * A TIMESTAMP and not the event object: nothing here should hold a DOM event alive
 * past its dispatch, and `timeStamp` is unique per dispatch and identical for every
 * listener of it.
 */
let consumedAt = -1

function isHandle(value: unknown): value is Handle {
  return typeof value === 'string' || typeof value === 'number'
}

/** A message for a session that has gone is dropped, never applied. */
function mine(payload: Payload): boolean {
  return handle.value !== null && payload.handle === handle.value
}

function clamp(value: number, low: number, high: number): number {
  return Math.max(low, Math.min(high, value))
}

function send(channel: string, payload: Payload = {}): void {
  if (handle.value === null) return
  emit(channel, { ...payload, handle: handle.value })
}

function samePath(left: string[], right: string[]): boolean {
  if (left.length !== right.length) return false
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return false
  }
  return true
}

/** A row's group as the folder names it actually carries. */
function partsOf(row: Row): string[] {
  return row.group
    .split(GROUP_SEPARATOR)
    .map((part) => part.trim())
    .filter((part) => part !== '')
}

/** The entries of ONE level: the rows that sit exactly at `prefix`, and one folder
    per distinct name below it. */
function levelOf(prefix: string[]): Entry[] {
  const depth = prefix.length
  const out: Entry[] = []
  const folders = new Map<string, number>()

  for (const row of rows.value) {
    const parts = partsOf(row)

    let inside = true
    for (let index = 0; index < depth; index += 1) {
      if (parts[index] !== prefix[index]) {
        inside = false
        break
      }
    }
    if (!inside) continue

    if (parts.length > depth) {
      const name = parts[depth]
      const seen = folders.get(name)
      if (seen === undefined) {
        folders.set(name, 1)
        out.push({ kind: 'folder', name, count: 1 })
      } else {
        folders.set(name, seen + 1)
      }
      continue
    }
    out.push({ kind: 'row', row })
  }

  // The counts are only known once every row has been walked.
  return out.map((entry) =>
    entry.kind === 'folder' ? { ...entry, count: folders.get(entry.name) ?? 1 } : entry
  )
}

/**
 * ONE COLUMN PER PREFIX of the trail, root first.
 *
 * A level that came back empty ends the cascade rather than drawing an empty frame:
 * `rows` can be replaced under an open trail, and a column of nothing is worse than
 * a trail that quietly got shorter.
 */
const columns = computed<Column[]>(() => {
  const out: Column[] = []
  for (let depth = 0; depth <= path.value.length; depth += 1) {
    const entries = levelOf(path.value.slice(0, depth))
    if (depth > 0 && entries.length === 0) break
    out.push({ depth, entries, openName: path.value[depth] ?? '' })
  }
  return out
})

const showList = computed(
  () => open.value && (loading.value || failed.value || (columns.value[0]?.entries.length ?? 0) > 0)
)

/* `showHint` is gone with the plate it gated, and the hint and back labels with it:
   this surface carries no instructions. A player who is holding the key already
   knows they are holding it. */

/* NO FOOT. It carried the trail and a row count as pass-02 "technical filler", and
   the owner does not want it. It is not missed by the cascade either: a crumb is what
   a ONE-LEVEL-AT-A-TIME list needs to say where it is, and every level of this one is
   already on screen with its folder row lit. */

/** The cascade's full width, computed rather than measured: it is the only way the
    wrapper's `left` can be right in the SAME frame the column arrives in. A measured
    width is one frame late, and one frame late on a flipped cascade is a visible
    jump of the whole trail. */
const span = computed(() => {
  const count = columns.value.length
  return count * COLUMN_W + Math.max(0, count - 1) * COLUMN_GAP
})

const flipped = computed(() => side.value < 0)

/**
 * The wrapper's left edge.
 *
 * Growing RIGHT this does not depend on `span` at all, so the root column never
 * moves however deep the trail goes. Growing LEFT the wrapper's left edge moves but
 * its right edge -- where the root column sits, because the columns are laid out
 * `row-reverse` -- does not. Either way the parent stays put, which is the whole
 * point of a cascade.
 *
 * The clamp is the last resort: a trail deep enough to leave the screen shifts as a
 * WHOLE rather than letting a column fall off the edge or grow back the other way.
 */
const left = computed(() => {
  const x = anchor.value.x * view.value.w
  const wanted = side.value < 0 ? x - GAP - span.value : x + GAP
  return clamp(wanted, EDGE, Math.max(EDGE, view.value.w - span.value - EDGE))
})

/** Which side the cascade grows on, decided once from the room beside the click. */
function decideSide(): void {
  if (side.value !== 0) return
  const x = anchor.value.x * view.value.w
  const roomRight = view.value.w - EDGE - (x + GAP)
  const roomLeft = x - GAP - EDGE
  // The test is TWO columns' worth, not one: a root column that fits with nothing to
  // spare would have to shift the entire cascade on the very first folder.
  const wanted = COLUMN_W + STEP
  if (roomRight >= wanted) side.value = 1
  else if (roomLeft >= wanted) side.value = -1
  else side.value = roomRight >= roomLeft ? 1 : -1
}

/**
 * The vertical placement, and the only part of the geometry that has to be measured:
 * the cascade's height is whichever column is tallest, and that is a layout fact.
 */
function place(): void {
  frame = 0
  const node = listEl.value
  if (!node) return
  const y = anchor.value.y * view.value.h
  top.value = clamp(y - EYE_HALF, EDGE, Math.max(EDGE, view.value.h - node.offsetHeight - EDGE))
}

function schedule(): void {
  if (frame === 0) frame = requestAnimationFrame(place)
}

function cancelIntent(): void {
  if (intentTimer !== undefined) clearTimeout(intentTimer)
  intentTimer = undefined
  intent = null
}

function clearTimers(): void {
  if (hoverTimer !== undefined) clearTimeout(hoverTimer)
  if (loadingTimer !== undefined) clearTimeout(loadingTimer)
  hoverTimer = undefined
  loadingTimer = undefined
  cancelIntent()
}

function blank(): void {
  clearTimers()
  busy.value = false
  loading.value = false
  failed.value = false
  available.value = false
  rows.value = []
  path.value = []
  pendingToken.value = ''
  sentPoint = null
  side.value = 0
  aim = null
}

function shut(): void {
  blank()
  open.value = false
  handle.value = null
  keyboard.value = false
  consumedAt = -1
  pressed = false
  pressPoint = null
  release?.()
  release = undefined
}

/** One column's element, by depth. */
function columnAt(depth: number): HTMLElement | null {
  const node = listEl.value
  if (!node) return null
  return node.querySelector<HTMLElement>(`[data-depth="${depth}"]`)
}

/** The rows one column offers the keyboard, in the order they are drawn. */
function rowsIn(depth: number): HTMLElement[] {
  const column = columnAt(depth)
  if (!column) return []
  return Array.from(column.querySelectorAll<HTMLElement>('[role="button"]:not([aria-disabled="true"])'))
}

function focusedRow(): HTMLElement | null {
  const active = document.activeElement as HTMLElement | null
  return active?.closest<HTMLElement>('[role="button"]') ?? null
}

/** Which column the keyboard is in. Nothing focused means the column the player most
    recently opened, which is the one they are working in. */
function focusedDepth(): number {
  const active = document.activeElement as HTMLElement | null
  const column = active?.closest<HTMLElement>('[data-depth]') ?? null
  const depth = column ? Number(column.dataset.depth) : Number.NaN
  return Number.isFinite(depth) ? depth : path.value.length
}

/**
 * THE SAFE CORRIDOR -- "laisse une marge curseur pour pas que ce soit trop dificile
 * d'acceder".
 *
 * When a column opens, a triangle is pinned between the pointer (its apex) and the
 * two near corners of the new column (its base). While the pointer is inside that
 * triangle it is IN TRANSIT: it is allowed to cross the parent's other rows without
 * any of them taking the cascade down behind it.
 *
 * WHY A TRIANGLE AND NOT A GRACE PERIOD. A grace period is blind -- it holds the
 * cascade for N ms whatever the pointer is doing, so either it is too short for a
 * slow diagonal or it is long enough to make a deliberate move to a sibling feel
 * stuck. The triangle is direction-aware for free, because of its shape: it is
 * narrow at the pointer and wide at the column, so moving STRAIGHT DOWN the parent
 * leaves it within a few pixels and the switch happens at once, while moving TOWARD
 * the column stays inside it for the whole journey. Position only -- no velocity, so
 * no jitter to filter, and it cannot be fooled by a pause mid-move.
 *
 * It is bounded by `AIM_HOLD_MS` all the same: a pointer that stops inside the
 * corridor gets what it is pointing at rather than nothing.
 */
function inCorridor(px: number, py: number): boolean {
  if (aim === null) return false
  const { ax, ay, nx, top: ty, bottom: by } = aim
  // The cross product of the point against each edge, walking apex -> top -> bottom.
  // The base is vertical, so its term reduces: only which SIDE of `nx` the point is
  // on survives, which is also the only thing that edge has to say.
  const side1 = (nx - ax) * (py - ay) - (ty - ay) * (px - ax)
  const side2 = -(by - ty) * (px - nx)
  const side3 = (ax - nx) * (py - by) - (ay - by) * (px - nx)
  const negative = side1 < 0 || side2 < 0 || side3 < 0
  const positive = side1 > 0 || side2 > 0 || side3 > 0
  // Inside, or on an edge: one sign only. The test is orientation-agnostic, so it
  // works unchanged for a cascade growing left.
  return !(negative && positive)
}

/** Pins the corridor from the pointer to the column that just opened. */
function armAim(depth: number): void {
  aim = null
  if (depth < 1 || pointer.x < 0) return
  void nextTick(() => {
    const column = columnAt(depth)
    if (!column) return
    // The RENDERED box, transform and all: the column is tilted, and what the pointer
    // has to reach is where it is drawn, not where it would be unrotated.
    const box = column.getBoundingClientRect()
    aim = {
      ax: pointer.x,
      ay: pointer.y,
      nx: flipped.value ? box.right : box.left,
      top: box.top - AIM_PAD,
      bottom: box.bottom + AIM_PAD
    }
  })
}

/**
 * Opens or closes columns so the trail is `next`.
 *
 * RE-REASONED FOR HOVER, because the bug in the header gets easier to hit here, not
 * harder: a level can now change from a TIMER while the pointer is inside the list,
 * not only from a click handler.
 *
 *   - A click on a row is still guarded, and by a stronger guard than before: the
 *     latch and the `stopPropagation` are both on the CASCADE WRAPPER, which no
 *     level change ever unmounts. The old guard asked the clicked element whether it
 *     was still in the tree, which is the question that got the wrong answer.
 *   - A click on a FOLDER no longer even unmounts its own row: a folder click adds a
 *     column and leaves the one it was clicked in exactly as it was. The gesture that
 *     used to trip the bug cannot trip it now for a second, structural reason.
 *   - What IS new is a level arriving between a press and its release, since the
 *     click's target is hit-tested at release. `pressed` is why that cannot happen:
 *     a hover intent will not apply while a button is down.
 */
function applyPath(next: string[], viaPointer: boolean): void {
  if (busy.value) return
  cancelIntent()
  if (samePath(next, path.value)) return
  path.value = next
  if (viaPointer) {
    keyboard.value = false
    armAim(next.length)
  } else {
    aim = null
  }
  void nextTick(place)
}

/** Schedules a level change for a row the pointer is resting on. */
function arm(next: string[], el: HTMLElement): void {
  if (intentTimer !== undefined) clearTimeout(intentTimer)
  intent = { next, el }
  // In the corridor the pointer is on its way somewhere and gets the long leash; out
  // of it, it is pointing at this row and gets the short one.
  const delay = inCorridor(pointer.x, pointer.y) ? AIM_HOLD_MS : HOVER_INTENT_MS
  intentTimer = setTimeout(() => {
    intentTimer = undefined
    const wanted = intent
    intent = null
    if (wanted === null || pressed) return
    // The pointer has to still be there. A hover the player has already left is not
    // an instruction, and without this a pointer sweeping off the cascade would open
    // a column behind it.
    if (!wanted.el.matches(':hover')) return
    applyPath(wanted.next, true)
  }, delay)
}

/** A row asks for the trail it implies: a folder for its own level, anything else
    for the level it sits in, which closes whatever is deeper. */
function intend(next: string[], event: MouseEvent): void {
  if (busy.value || keyboard.value) return
  const el = event.currentTarget
  if (!(el instanceof HTMLElement)) return
  if (samePath(next, path.value)) {
    // Already showing: whatever was scheduled is no longer wanted.
    cancelIntent()
    return
  }
  if (intent !== null && intent.el === el && samePath(intent.next, next)) return
  arm(next, el)
}

function choose(row: Row): void {
  if (busy.value) return
  cancelIntent()
  // Disabled here and not by Lua's answer: the list must stop taking clicks the
  // instant one is sent, or a second click races the first one's resolution.
  busy.value = true
  pendingToken.value = row.token
  send('opx:target:select', { token: row.token })
}

function onPointerMove(event: MouseEvent): void {
  if (event.clientX === pointer.x && event.clientY === pointer.y) return
  pointer.x = event.clientX
  pointer.y = event.clientY

  // THE POINTER MOVED, SO THE POINTER IS DRIVING: the focus ring goes and hovering
  // may open folders again. This is above the early return on purpose. `intend`
  // refuses to schedule anything while the keyboard has the list, and the only other
  // place that cleared this flag was below a `return` taken whenever the list is up
  // -- so a player who pressed one arrow key could never go back to hovering.
  keyboard.value = false

  if (aim !== null && !inCorridor(pointer.x, pointer.y)) {
    // The pointer left the corridor, so it was not going to the child after all: a
    // switch that was waiting on it stops waiting. This is what keeps a deliberate
    // move to a sibling prompt instead of costing the full AIM_HOLD_MS.
    aim = null
    if (intent !== null) arm(intent.next, intent.el)
  }

  if (!open.value || busy.value || showList.value) return
  const point = {
    x: clamp(event.clientX / view.value.w, 0, 1),
    y: clamp(event.clientY / view.value.h, 0, 1)
  }
  eye.value = point
  if (hoverTimer !== undefined) return
  hoverTimer = setTimeout(() => {
    hoverTimer = undefined
    if (!open.value || busy.value || showList.value) return
    if (sentPoint && sentPoint.x === eye.value.x && sentPoint.y === eye.value.y) return
    sentPoint = { ...eye.value }
    send('opx:target:hover', sentPoint)
  }, hoverMs)
}

/**
 * A click that began inside the cascade is the CASCADE's click and never a cancel.
 *
 * TWO PHASES, and they are not interchangeable. The latch is taken in the CAPTURE
 * phase, on the way down, because that is the last moment at which the DOM still
 * says the truth -- and it must not stop the event there, or the row it is on the
 * way to would never be clicked at all. The `stopPropagation` is the BUBBLE phase,
 * after the row has had it, and it is what keeps the click off `.eye-room`.
 *
 * BOTH LIVE ON THE WRAPPER, which is the load-bearing part: the wrapper is created
 * once per pick and no level change unmounts it, so it is in the retained event path
 * of every click on every row of every column, whatever the columns did in between.
 */
function onListCapture(event: MouseEvent): void {
  consumedAt = event.timeStamp
}

function onListBubble(event: MouseEvent): void {
  event.stopPropagation()
}

/**
 * Whether a point is inside the cascade's own box, columns and the gaps between
 * them alike.
 *
 * THE GAPS ARE WHY THIS EXISTS. The wrapper is `pointer-events: none` and the
 * columns take the pointer back, so a click a few pixels wide of a row lands on
 * `.eye-room` and not on the list. That used to re-cast the ray, which was merely
 * odd; with the left button now meaning CANCEL it would tear the whole cascade down
 * for a near-miss. The box is the honest question -- "was the player aiming at the
 * list" -- and it is one `getBoundingClientRect` on a click, not on a move.
 */
function insideList(x: number, y: number): boolean {
  const node = listEl.value
  if (node === null) return false
  const box = node.getBoundingClientRect()
  return x >= box.left && x <= box.right && y >= box.top && y <= box.bottom
}

/**
 * THE LEFT BUTTON ANSWERS. A row and a folder take their own clicks; everything
 * this handler ever sees is a click on the world, and on the world the gesture
 * means "I am done".
 */
function onClick(event: MouseEvent): void {
  if (!open.value) return
  if (event.timeStamp === consumedAt) {
    consumedAt = -1
    return
  }
  // Aimed at the list and missed. See `insideList`.
  if (showList.value && insideList(event.clientX, event.clientY)) return
  send('opx:target:cancel')
}

/**
 * THE RIGHT BUTTON ASKS, and what it asks for depends on whether anything is up.
 *
 * `preventDefault` comes first and is unconditional: this is a browser, and the
 * browser's own menu over the middle of Night City is the one outcome that is never
 * wanted, eye or no eye.
 *
 * NOTHING UP -> A PICK, at the coordinates the button went DOWN at -- see
 * `pressPoint`. Lua casts the ray at that point and not at wherever the pointer
 * has since moved to.
 *
 * A CASCADE UP -> BACK: the deepest column closes and everything shallower stays on
 * screen, which with a cascade is what "back" means. At the root there is nothing
 * left to close, so it cancels.
 *
 * A PICK STILL RESOLVING -> CANCEL. `busy` spans the `LOADING_DELAY_MS` window in
 * which no list is drawn yet, and without this branch the gesture would report a
 * second pick on top of the first one.
 */
function onContextMenu(event: MouseEvent): void {
  event.preventDefault()
  // Taken before every branch, including the ones that never use it: a point left
  // behind by a press that turned out to mean "back" would be sent as the aim of
  // the NEXT pick.
  const press = pressPoint
  pressPoint = null
  if (!open.value) return

  if (showList.value || busy.value) {
    if (showList.value && !busy.value && path.value.length > 0) {
      applyPath(path.value.slice(0, -1), false)
      return
    }
    send('opx:target:cancel')
    return
  }

  const point = press ?? { x: event.clientX, y: event.clientY }
  send('opx:target:pick', {
    x: clamp(point.x / view.value.w, 0, 1),
    y: clamp(point.y / view.value.h, 0, 1)
  })
}

const VERTICAL = ['ArrowDown', 'ArrowUp', 'Home', 'End']

/** Descending is always toward the child column, which for a cascade growing left is
    the LEFT arrow. The keys follow what the player sees, not the array index. */
function onKeyDown(event: KeyboardEvent): void {
  if (!open.value || !showList.value) return
  const key = event.key
  const deeper = flipped.value ? 'ArrowLeft' : 'ArrowRight'
  const shallower = flipped.value ? 'ArrowRight' : 'ArrowLeft'

  if (VERTICAL.indexOf(key) !== -1) {
    event.preventDefault()
    // WITHIN ONE COLUMN. Walking the whole cascade with one pair of keys would make
    // the last row of a column lead into the first row of another level, which is
    // not what the eye sees.
    const buttons = rowsIn(focusedDepth())
    if (buttons.length === 0) return
    const current = buttons.indexOf(document.activeElement as HTMLElement)
    let index: number
    if (key === 'Home') index = 0
    else if (key === 'End') index = buttons.length - 1
    else if (current < 0) index = key === 'ArrowUp' ? buttons.length - 1 : 0
    else index = (current + (key === 'ArrowDown' ? 1 : -1) + buttons.length) % buttons.length
    keyboard.value = true
    buttons[index].focus()
    return
  }

  if (key === deeper) {
    const name = focusedRow()?.dataset.folder
    if (name === undefined || name === '') return
    event.preventDefault()
    const depth = focusedDepth()
    keyboard.value = true
    applyPath(path.value.slice(0, depth).concat([name]), false)
    void nextTick(() => {
      rowsIn(depth + 1)[0]?.focus()
    })
    return
  }

  if (key === shallower) {
    const depth = focusedDepth()
    if (depth < 1) return
    event.preventDefault()
    const name = path.value[depth - 1]
    keyboard.value = true
    applyPath(path.value.slice(0, depth - 1), false)
    void nextTick(() => {
      const back = rowsIn(depth - 1)
      const folder = back.find((el) => el.dataset.folder === name)
      ;(folder ?? back[0])?.focus()
    })
  }
}

function onResize(): void {
  view.value = { w: window.innerWidth, h: window.innerHeight }
  schedule()
}

function onBlur(): void {
  // A release that lands outside the window never reaches `onMouseUp`, and a
  // `pressed` left true makes `arm` drop every hover intent until the next click:
  // folders stop opening on hover for no visible reason.
  pressed = false
  pressPoint = null
  if (open.value) send('opx:target:cancel')
}

function onMouseDown(event: MouseEvent): void {
  pressed = true
  if (event.button === 2) pressPoint = { x: event.clientX, y: event.clientY }
}

function onMouseUp(): void {
  pressed = false
}

function readRows(value: unknown): Row[] {
  return records(value).map((entry) => ({
    token: text(entry.token),
    label: text(entry.label),
    description: text(entry.description),
    group: text(entry.group),
    icon: text(entry.icon, 'interact'),
    danger: bool(entry.danger),
    checked: typeof entry.checked === 'boolean' ? entry.checked : undefined
  }))
}

useBridge('opx:target:open', (payload: Payload) => {
  guard('target:open', () => {
    if (!isHandle(payload.handle)) return
    release?.()
    blank()
    handle.value = payload.handle
    hoverMs = clamp(num(payload.hoverMs, 90), 30, 1000)
    const given = table(payload.labels)
    labels.value = {
      looking: text(given.looking),
      unavailable: text(given.unavailable)
    }
    view.value = { w: window.innerWidth, h: window.innerHeight }
    eye.value = { x: 0.5, y: 0.5 }
    anchor.value = { x: 0.5, y: 0.5 }
    consumedAt = -1
    open.value = true
    release = acquireFocus({ id: 'target', onEscape: () => send('opx:target:cancel') })
  }, undefined)
})

useBridge('opx:target:hover', (payload: Payload) => {
  if (!mine(payload) || busy.value || showList.value) return
  available.value = payload.available === true
})

useBridge('opx:target:loading', (payload: Payload) => {
  guard('target:loading', () => {
    if (!mine(payload)) return
    clearTimers()
    busy.value = true
    failed.value = false
    rows.value = []
    path.value = []
    available.value = false
    aim = null
    // A fresh pick is a fresh anchor, so the side is decided again from it.
    side.value = 0
    anchor.value = { x: clamp(num(payload.x, 0.5), 0, 1), y: clamp(num(payload.y, 0.5), 0, 1) }
    decideSide()
    // Delayed, not immediate. Most picks answer inside this window and never draw a
    // panel at all; without the delay every click flashes a spinner.
    loadingTimer = setTimeout(() => {
      loadingTimer = undefined
      if (!open.value || !busy.value) return
      loading.value = true
      void nextTick(place)
    }, LOADING_DELAY_MS)
  }, undefined)
})

useBridge('opx:target:empty', (payload: Payload) => {
  // Nothing to offer: the cascade goes away and the surface waits again, as if
  // nothing had been clicked. Deliberately not an empty panel and not a sentence.
  if (!mine(payload)) return
  blank()
})

useBridge('opx:target:menu', (payload: Payload) => {
  guard('target:menu', () => {
    if (!mine(payload)) return
    clearTimers()
    busy.value = false
    loading.value = false
    failed.value = false
    rows.value = readRows(payload.options)
    path.value = []
    available.value = rows.value.length > 0
    aim = null
    anchor.value = { x: clamp(num(payload.x, anchor.value.x), 0, 1), y: clamp(num(payload.y, anchor.value.y), 0, 1) }
    decideSide()
    keyboard.value = false
    void nextTick(place)
  }, undefined)
})

useBridge('opx:target:busy', (payload: Payload) => {
  if (!mine(payload)) return
  cancelIntent()
  busy.value = true
  pendingToken.value = text(payload.token)
})

// A confirm row's first click: the row is relabelled in place, wherever it sits in
// the folders, and the next click on it is the one Lua runs.
useBridge('opx:target:confirm', (payload: Payload) => {
  guard('target:confirm', () => {
    if (!mine(payload)) return
    const token = text(payload.token)
    const label = text(payload.label)
    busy.value = false
    pendingToken.value = ''
    if (token === '' || label === '') return
    rows.value = rows.value.map((row) => (row.token === token ? { ...row, label } : row))
  }, undefined)
})

useBridge('opx:target:error', (payload: Payload) => {
  if (!mine(payload)) return
  busy.value = false
  loading.value = false
  pendingToken.value = ''
  failed.value = true
  void nextTick(place)
})

useBridge('opx:target:close', (payload: Payload) => {
  if (payload.handle !== undefined && !mine(payload)) return
  shut()
})

window.addEventListener('resize', onResize)
window.addEventListener('blur', onBlur)
window.addEventListener('keydown', onKeyDown)
window.addEventListener('mousedown', onMouseDown, true)
window.addEventListener('mouseup', onMouseUp, true)

onUnmounted(() => {
  window.removeEventListener('resize', onResize)
  window.removeEventListener('blur', onBlur)
  window.removeEventListener('keydown', onKeyDown)
  window.removeEventListener('mousedown', onMouseDown, true)
  window.removeEventListener('mouseup', onMouseUp, true)
  clearTimers()
  if (frame !== 0) cancelAnimationFrame(frame)
  frame = 0
  release?.()
})
</script>

<template>
  <div
    v-if="open"
    class="eye-room"
    :class="{ available, busy }"
    @mousemove="onPointerMove"
    @click="onClick"
    @contextmenu="onContextMenu"
  >
    <!-- THE CASCADE. Both click guards live HERE, on the one element no level change
         unmounts: the capture handler latches on the way down, the bubble handler
         stops on the way back up. It is `pointer-events: none` and the columns take
         the pointer back, so the gaps between them fall through to `.eye-room` --
         which is what `insideList` is there to forgive. -->
    <div
      v-if="showList"
      ref="listEl"
      class="cascade"
      :class="{ flip: flipped }"
      :style="{ left: `${left}px`, top: `${top}px`, width: `${span}px` }"
      @click.capture="onListCapture"
      @click="onListBubble"
    >
      <!-- A COLUMN IS NOT A PANEL. There is no enclosure: no chamfered outline, no
           arete, no backing and no interlace. The level is its rows, sitting loose on
           the gameplay plane, and the only thing holding them together is that they
           share an x and a tilt. -->
      <div v-for="col in columns" :key="col.depth" class="column" :data-depth="col.depth">
        <div class="plane" :class="{ keyboard }">
          <template v-if="col.depth === 0">
            <p v-if="loading" class="status">
              <span class="spin" aria-hidden="true" />
              <span>{{ labels.looking }}</span>
            </p>

            <!-- THE REFUSAL STAYS ABOVE THE ROWS and the rows stay clickable: Lua
                 said this pick could not be run, not that the list was wrong. -->
            <p v-else-if="failed" class="status bad">{{ labels.unavailable }}</p>
          </template>

          <div v-if="!(loading && col.depth === 0)" class="rows" role="menu">
            <!-- THE ENTRANCE IS ON THE SLOT, NOT ON THE ROW -- the menu's fix, and
                 the reason these buttons felt slow. A row's classes change under
                 the pointer (`open`, `pending`), and an `animation` that differs
                 between two states is CANCELLED AND RESTARTED by the change, so a
                 folder the pointer left replayed its whole stutter from invisible.
                 The slot is what the keyed v-for creates and its classes never
                 change, so it plays `.op-enter` exactly once, like a menu row.
                 NO STAGGER: every row of a column lands together. A column opens
                 on every folder the pointer crosses, so a per-row walk replayed
                 on each one and read as the rows trickling in, where the menu's
                 buttons just appear. -->
            <div
              v-for="entry in col.entries"
              :key="entry.kind === 'folder' ? `d:${entry.name}` : `r:${entry.row.token}`"
              class="slot op-enter"
              style="--op-slot: 0"
            >
              <!-- A FOLDER: the same frame, the count where a value goes and `>` in
                   the affordance column. Pointing at it opens its column beside
                   this one; it stays lit for as long as that column is up. -->
              <div
                v-if="entry.kind === 'folder'"
                class="row"
                data-augmented-ui="tr-clip border"
                :class="{ off: busy, open: col.openName === entry.name }"

                :data-folder="entry.name"
                role="button"
                :tabindex="busy ? -1 : 0"
                :aria-disabled="busy"
                :aria-expanded="col.openName === entry.name"
                @mouseenter="intend(path.slice(0, col.depth).concat([entry.name]), $event)"
                @click="applyPath(path.slice(0, col.depth).concat([entry.name]), true)"
                @keydown.enter.prevent="applyPath(path.slice(0, col.depth).concat([entry.name]), false)"
                @keydown.space.prevent="applyPath(path.slice(0, col.depth).concat([entry.name]), false)"
              >
                <span class="glyph" aria-hidden="true">
                  <svg viewBox="0 0 24 24">
                    <path v-for="(d, index) in glyphPaths('folder')" :key="index" :d="d" />
                  </svg>
                </span>
                <span class="label op-label op-truncate">{{ entry.name }}</span>
                <span class="value op-value op-truncate">{{ entry.count }}</span>
                <span class="mark">&gt;</span>
              </div>

              <!-- AN ACTION. Pointing at it closes whatever is deeper than the
                   column it lives in, which is how a cascade retreats. -->
              <div
                v-else
                class="row"
                data-augmented-ui="tr-clip border"
                :class="{
                  danger: entry.row.danger,
                  pending: entry.row.token === pendingToken,
                  off: busy && entry.row.token !== pendingToken
                }"

                role="button"
                :tabindex="busy ? -1 : 0"
                :aria-disabled="busy"
                @mouseenter="intend(path.slice(0, col.depth), $event)"
                @click="choose(entry.row)"
                @keydown.enter.prevent="choose(entry.row)"
                @keydown.space.prevent="choose(entry.row)"
              >
                <span class="glyph" aria-hidden="true">
                  <span v-if="entry.row.token === pendingToken" class="spin" />
                  <svg v-else viewBox="0 0 24 24">
                    <path v-for="(d, index) in glyphPaths(entry.row.icon)" :key="index" :d="d" />
                  </svg>
                </span>
                <span class="label op-label op-truncate">{{ entry.row.label }}</span>
                <span
                  v-if="entry.row.checked !== undefined"
                  class="check"
                  :class="{ ticked: entry.row.checked }"
                  role="checkbox"
                  :aria-checked="entry.row.checked"
                >
                  <!-- The tick draws in after the frame lands and wipes instantly:
                       a stroke-dashoffset transition with a delay. -->
                  <svg viewBox="0 0 13 13" aria-hidden="true"><path d="M2.6 6.8 5 9.2 10 3.6" /></svg>
                </span>
                <span v-if="entry.row.description" class="hint">{{ entry.row.description }}</span>
              </div>
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

   The menu surface is the agreed reference and this is its idiom, not a variation
   on it: nothing is filled, a CONTROL is a closed frame with the top-right corner
   chamfered, the red has three steps plus a hot rung, everything carries a black
   shadow, and state changes cut rather than fade.

   WHAT IS NOT THE MENU, and all four are forced by what this surface is:

     1. IT IS ANCHORED TO A POINT, NOT TO A SCREEN EDGE, so the leading edge is
        decided at runtime. Every mirrored thing -- the tilt sign, the direction the
        cascade grows, the row's runway -- is keyed off `.flip`.
     2. IT IS A CASCADE. One column per level of the open trail, laid out by flexbox
        with one `gap`, reversed as a WHOLE when it grows left. A column is its own
        plane: its own perspective, its own tilt, its own containment.
     3. A COLUMN HAS NO ENCLOSURE. No chamfered container outline, no arete, no
        backing -- and NO INTERLACE, which is the part that needed deciding rather
        than deleting. The interlace was justified as the thing that stops an
        unfilled FRAME reading as a web page floating in the air. With the frame
        gone there is nothing for it to sit inside, so a striped rectangle with a
        hard edge IS that floating web page: it would be the only drawn boundary
        left, and it would be one nobody asked for. It goes with the box. What
        holds a column together now is that its rows share an x and a tilt, and
        what keeps them legible over a blown-out plaza is the black underlay in
        the plate under each row and the two-pass text-shadow -- both per
        row, both already there.
     4. NO RETICLE. The state Lua reports about the point under the pointer is on
        the CURSOR now (`default` / `pointer` / `progress`), which is what a cursor
        is for and one fewer thing drawn over the street.

   THE ROW IS AUGMENTED. Five SVG data URIs used to live here, one per state, each
   a copy of the same chamfer path; the shape is `--aug-tr` now and a state is
   `--aug-border-bg` plus `color`. Still no fill beyond the plate and still no
   filter per row at rest, because this page composites over live gameplay at a
   frame rate fixed when the surface was created.

   THE TWO BLOOMS ARE `drop-shadow`, NOT `box-shadow`, and that is forced: the
   element is clipped, and a clip shears an outset shadow along the diagonal --
   the same mismatch that used to square off the corner the whole shape is about.
   They are on `danger:hover` and `pending`, which change when the player points
   at something or Lua starts working, never on a clock.
   ========================================================================== */

/* The room owns the whole screen while it is up: it reads the pointer everywhere.
   Closed, this element does not exist at all, so the surface underneath is
   untouched.

   IT DRAWS NO RETICLE. It used to replace the system cursor with an eye, which is
   one more thing on screen than the surface needs -- but the eye was also the only
   thing saying whether the pointer was over something usable, and dropping it
   silently would drop that. So the state moved onto the cursor itself: the pointer
   is the affordance, which is what a pointer is for. */
.eye-room {
  position: fixed;
  inset: 0;
  cursor: default;
  user-select: none;
}

/* Lua says whether the point under the pointer can be acted on, and whether it is
   waiting on the server. Both are one declaration now. */
.eye-room.available {
  cursor: pointer;
}

.eye-room.busy {
  cursor: progress;
}

/* =============================================================================
   THE CASCADE -- the wrapper. It owns position and nothing else: no perspective,
   no containment and no clip, because its children have to be free to be their
   own planes. `width` is set inline from the arithmetic span so it always matches
   the flex row inside it exactly.

   POINTER-EVENTS: NONE, and it matters twice. The wrapper's box covers the gaps
   between the columns and the empty band under a short one; taking the pointer
   there would turn the gap the owner asked for into dead space and swallow a
   click that should have been a new pick. The columns take it back. Both click
   guards still fire, because `pointer-events` decides what is HIT, not what is in
   the event path of whatever was.
   ========================================================================== */
.cascade {
  position: absolute;
  display: flex;
  align-items: flex-start;
  /* THE ONLY SEPARATION THERE IS, now that a column has no outline. See COLUMN_GAP
     in the script: it must match `span`, which is arithmetic, so the number is
     declared in both places and neither may drift. */
  gap: var(--op-space-4);
  pointer-events: none;
}

/* THE WHOLE CASCADE FLIPS, NEVER ONE COLUMN. `row-reverse` puts the root column at
   the right-hand end and grows every child leftward from it, which is why the root
   stays put: the wrapper's left edge moves, its right edge does not. */
.cascade.flip {
  flex-direction: row-reverse;
}

/* =============================================================================
   A COLUMN -- one level. Its own plane, its own containment.
   ========================================================================== */
.column {
  flex: none;
  width: 224px;
  max-height: calc(100vh - 24px);
  display: flex;
  cursor: default;
  pointer-events: auto;
  perspective: var(--op-persp);
  /* Nothing inside can affect layout or paint outside it, so one row changing never
     asks the compositor to consider the other columns. */
  contain: layout paint style;
  --pop: 7px;
  --tilt: var(--op-tilt);
  --origin: left center;
  animation: cut-in 120ms var(--op-stutter);
}

.cascade.flip .column {
  --pop: -7px;
  --tilt: calc(var(--op-tilt) * -1);
  --origin: right center;
}

@keyframes cut-in {
  from { opacity: 0; }
  to { opacity: 1; }
}

/* =============================================================================
   THE PLANE -- what is left of the frame, which is the TILT and nothing else.

   No outline, no chamfer, no arete, no backing and no interlace: see point 3 in
   the header. It is not a box any more, so it is not called one. The `.flip` rule
   that used to mirror the chamfer and the arete is gone with them -- the only
   mirrored things left, `--tilt` and `--origin`, are set on the column.
   ========================================================================== */
.plane {
  position: relative;
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  min-height: 0;
  max-height: inherit;
  transform-origin: var(--origin);
  transform: rotateY(var(--tilt));
}

/* =============================================================================
   THE ROWS
   ========================================================================== */
.rows {
  position: relative;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  /* The side padding is the chosen row's runway: it leaves the column by `--pop`
     and the perspective widens it slightly on the way out, and both have to land
     inside a frame that is a clip-path. */
  padding: var(--op-space-2) var(--op-space-3);
  min-height: 0;
}

/* The slot carries the entrance (`.op-enter`) and nothing else; the row fills it. */
.slot {
  display: flex;
  min-width: 0;
}

.slot > .row {
  flex: 1;
  min-width: 0;
}

/* A row: a closed 1px frame with a chamfered top-right corner, and text.

   IT HAS A GROUND NOW. This comment used to end "there is nothing behind it and
   there never will be", and the game settled it the other way: these rows are
   drawn over whatever the player is aiming at, which is the most cluttered
   backdrop any surface in this runtime gets, and the owner asked for a
   background under everything carrying text. The plate is per ROW rather than
   behind the column, for the reason the status chips take one each: the rows are
   separated by gaps, and one plate behind the lot paints the gaps too and turns
   a list of choices into a slab.

   `border-image-width` is 8px while `border-width` is 1px, so the image draws its
   8px corner tiles while layout reserves one and the chamfer stays full size at any
   row width. */
.row {
  position: relative;
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  flex-wrap: wrap;
  min-width: 0;
  padding: var(--op-space-1) var(--op-space-2) calc(var(--op-space-1) + 1px);
  color: var(--op-red-text);
  white-space: nowrap;
  cursor: pointer;
  /* THE GROUND IS IN THE SPRITE, not behind it. A `background` fills the BORDER
     BOX, so it painted the very corner the chamfer had just cut off and squared
     it back up -- the same shape mismatch an outset shadow has, and the reason
     both are gone from every chamfered element. `fill` makes the border-image
     paint its middle tile too, so the ground IS the cut shape. The chosen row
     changes ground by changing sprite, like every other state on this row. */
  /* The ink stays, plate or no plate: the plate holds a row against a bright
     street and the shadow is what keeps a glyph's own edge crisp on top of it.
     A text-shadow INHERITS, so this one declaration carries the label, the
     count, the mark and the description. Two passes: the tight dark one gives an
     edge its contrast, the wide soft one lifts the row off a blown-out backdrop. */
  text-shadow:
    0 1px 2px rgba(0, 0, 0, 0.95),
    0 0 9px rgba(0, 0, 0, 0.8);
  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: var(--op-red-idle);
  background: var(--op-plate);
  /* NO `box-shadow` HERE. There was one -- `0 1px 7px` black, to keep a 1.4px stroke
     alive over a daylight plaza -- and it was the bug the owner spotted: an outset
     shadow follows the BORDER BOX, so it ran past the diagonal and squared off the
     chamfer. The shadow is a stroke inside the sprite now. */
  /* 80ms, the menu's: the step out of the column is the pointer's travel, and
     a slower one is a button that answers late. */
  transition:
    color var(--op-dur-fast) linear,
    transform 80ms var(--op-ease);
}

.row:focus {
  outline: none;
}

/* The column is held open whether or not the glyph inside it draws, so a level of
   folders and a level of actions keep every label on one x. */
.glyph {
  flex: none;
  display: grid;
  place-items: center;
  width: 15px;
  height: 15px;
}

.glyph svg {
  display: block;
  width: 100%;
  height: 100%;
  fill: none;
  /* The stroke follows the row colour, so the whole icon restates on hover and on
     the open folder without a second declaration anywhere. */
  stroke: currentcolor;
  stroke-width: 1.9;
  stroke-linecap: round;
  stroke-linejoin: round;
  /* A stroke takes no text-shadow. One drop-shadow on a 15px icon is the cheapest
     filter this surface could be asked to carry. */
  filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.95));
}

/* The cut itself is `.op-truncate` in `design-system/surface.css`, and this row is
   the reason the class exists: a long row label wrapped onto a second line and
   pushed the row's own height around instead of being cut. A row on the eye is one
   line -- whoever registered it chose the words, and a list whose rows change
   height as the ray moves is a list that cannot be read, because the row the
   pointer is over is no longer the row it was aimed at. */
.label {
  flex: 0 1 auto;
}

.value {
  flex: none;
  margin-left: auto;
  max-width: 45%;
  opacity: 0.88;
}

/* The affordance column, always last so every mark lands at the same x. */
.mark {
  flex: none;
  font: 700 var(--op-fs-meta) / 1 var(--op-font-mono);
}

.hint {
  /* The one place a row wraps. A description is a sentence, not a label. */
  flex: 1 0 100%;
  font: 400 var(--op-fs-meta) / 1.35 var(--op-font-body);
  color: var(--op-text-dim);
  white-space: normal;
}

/* The checkbox is a frame too, and its tick is the only fill left on this surface
   -- 13 pixels square, a mark rather than a backdrop. */
.check {
  flex: none;
  margin-left: auto;
  width: 13px;
  height: 13px;
  border: 1px solid currentcolor;
  transition: background var(--op-dur-fast) linear;
}

.value + .check {
  margin-left: var(--op-space-1);
}

.check svg {
  display: block;
  width: 100%;
  height: 100%;
  fill: none;
  stroke: currentcolor;
  stroke-width: 2.2;
  stroke-linecap: square;
  stroke-dasharray: 13;
  stroke-dashoffset: 13;
  transition: stroke-dashoffset var(--op-dur) var(--op-ease) var(--op-dur-fast);
}

.check.ticked svg {
  stroke-dashoffset: 0;
}

/* --- HOVER: denser red, no bloom -------------------------------------------
   An OPEN folder is excluded: it is already in the strongest state this surface
   has, and dropping it to the hover tone while the pointer rests on it would say
   the column it opened had closed. */
.row:hover:not(.off):not(.pending):not(.open),
.plane.keyboard .row:focus:not(.off):not(.pending):not(.open) {
  color: var(--op-red);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2px;
  background: var(--op-plate-lit);
  /* THE MENU'S CHOSEN ROW, on the row under the pointer: the same step out of
     the column and toward the player, on the same 80ms the `.row` transition
     already carries, so pointing down a column reads exactly like arrowing
     down the menu. It used to only recolour, and the eye felt like a second,
     flatter surface beside the menu it is supposed to be. */
  transform: translate3d(var(--pop), 0, 14px);
  filter: drop-shadow(0 0 6px var(--op-red-glow));
}

.row:hover:not(.off):not(.pending):not(.open) .label,
.plane.keyboard .row:focus:not(.off):not(.pending):not(.open) .label {
  letter-spacing: 0.055em;
  text-shadow: var(--op-ink), 0 0 10px var(--op-red-glow);
}

/* --- OPEN: the folder whose column is up beside this one. Lit and blooming, and
       it stays that way while the pointer works over there -- it is the only thing
       joining a column to the row that produced it. No pop: the pop belongs to
       the row under the pointer and to the committing one, and a folder that
       stepped out of the plane would break the line its own column is aligned to.

   THE BLOOM IS A `drop-shadow`, AND IT HAD TO CHANGE. It was an outset
   `box-shadow`, defended here on the grounds that a soft glow has no edge for the
   diagonal to disagree with -- true while the row was a `border-image` on an
   unclipped box. The row is clipped now, and a clip shears an outset shadow
   whatever its blur, so the glow is a filter that follows the cut. One row is
   open at a time and it changes when the player points somewhere else.
   ---------------------------------------------------------------------------- */
.row.open {
  color: var(--op-red);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2.4px;
  background: var(--op-plate-lit);
  filter: drop-shadow(0 0 6px var(--op-red-glow));
}

.row.open .label {
  text-shadow: 0 0 10px var(--op-red-glow);
}

.row.open .mark {
  opacity: 1;
}

/* --- DANGER: the hot rung of the red, heavier. NOT white and not a second hue:
       an alarm here climbs in intensity inside the one voice the surface has. ---- */
.row.danger {
  color: var(--op-alarm);
  --aug-border-bg: var(--op-alarm);
  --aug-border-all: 2px;
}

.row.danger .label {
  font-weight: 700;
  letter-spacing: 0.055em;
}

.row.danger:hover:not(.off):not(.pending),
.plane.keyboard .row.danger:focus:not(.off):not(.pending) {
  color: var(--op-alarm);
  --aug-border-bg: var(--op-alarm);
  --aug-border-all: 2px;
  transform: translate3d(var(--pop), 0, 14px);
  filter: drop-shadow(0 0 5px var(--op-alarm-glow));
}

/* --- PENDING: the row Lua is working on. Lit, blooming, and the one thing that
       leaves the plane -- by `--pop` and 14px toward the player, like the menu. The bloom
       is a box-shadow and not a filter: a filter here would give one row its own
       backing store inside a surface that repaints over live gameplay. ---------- */
.row.pending {
  color: var(--op-red);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2.4px;
  background: var(--op-plate-lit);
  transform: translate3d(var(--pop), 0, 14px);
  filter: drop-shadow(0 0 6px var(--op-red-glow));
  cursor: default;
}

.row.pending .label {
  text-shadow: 0 0 10px var(--op-red-glow);
}

.row.pending .check.ticked {
  background: var(--op-red);
}

/* The one place the tick is not `currentcolor`: on the filled box it would be red
   on red. */
.row.pending .check.ticked svg {
  stroke: var(--op-ink-on);
}

/* --- OFF: every other row, while one is committing --------------------------- */
.row.off {
  color: var(--op-text-faint);
  cursor: default;
  --aug-border-bg: rgba(174, 211, 224, 0.14);
}

.row.off .hint {
  color: var(--op-text-faint);
}

/* =============================================================================
   STATUS -- the delayed spinner, and the refusal.
   ========================================================================== */
.status {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  margin: 0;
  padding: var(--op-space-3);
  /* The ground, the same one the rows take: this line stands in for them and is
     read in the same place, against the same street. */
  background: var(--op-plate);
  font: 600 var(--op-fs-micro) / 1.3 var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  text-transform: uppercase;
  color: var(--op-red-text);
  text-shadow:
    0 1px 2px rgba(0, 0, 0, 0.95),
    0 0 9px rgba(0, 0, 0, 0.8);
}

/* A FAILED status takes the hot rung and the weight, not a second colour. */
.status.bad {
  color: var(--op-alarm);
  font-weight: 700;
}

/* A stepped ring, not a smooth one: it cuts like everything else here, and it is a
   transform on a leaf node, which is the only animation this surface can afford to
   run while a pick resolves. */
.spin {
  flex: none;
  display: block;
  width: 10px;
  height: 10px;
  border: 1px solid var(--op-red-idle);
  border-top-color: var(--op-red);
  animation: scan 0.72s steps(8, end) infinite;
}

@keyframes scan {
  to { transform: rotate(360deg); }
}

/* =============================================================================
   THE HINT -- the line shown while nothing is picked. A LABEL and not a control,
   so it takes the frame but never the hover.
   ========================================================================== */
</style>
