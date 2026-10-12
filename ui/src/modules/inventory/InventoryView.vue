<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, reactive, ref, shallowRef, watch } from 'vue'
import { emit as send } from '@/bridge/channel'
import { guard, report } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { BridgeError, request } from '@/bridge/rpc'
import { bool, table } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import InventoryGrid from './InventoryGrid.vue'
import { GRID_WIDTH } from './geometry'
import { ammoOf, durabilityOf, grams, labelOf, loadPercent, serialOf, weightOf } from './format'
import {
  readCatalogEntry,
  readConfig,
  readContainer,
  readNearby,
  readTabs
} from './types'
import type { CatalogEntry, Container, Handle, NearbyPlayer, ScreenConfig, TabSpec } from './types'

/**
 * THE INVENTORY -- the bag on the left, whatever is open beside it on the right.
 *
 * THE PAGE SENDS INTENTS. It reports that the player dragged slot 3 of container
 * 41 onto slot 9 of container 58. Whether that is a move, a stack, a swap or a
 * refusal is decided in Lua, along with what the bag then weighs. Nothing here
 * writes a count, a weight or a slot; every number drawn is one Lua last pushed.
 *
 * The handle: Lua opens with a spec carrying a handle, every emit echoes it, and
 * a payload carrying a different one belongs to a screen that has been replaced
 * and is dropped. A staff search opening over an inventory that is already up is
 * exactly that case.
 *
 * ── DESIGN PASS 02 ──────────────────────────────────────────────────────────
 *
 * THIS SURFACE DRAWS ITS OWN FRAMES AND ITS OWN ROWS, exactly as MenuView.vue
 * does and for the same reason. It used `OpPanel`, `OpRow`, `OpTabs`, `OpGauge`,
 * `OpKeyCap` and `OpScrim`; all six are gone from here and none of them was
 * touched, because all six are shared with prompts, target, panel and the entry
 * form. Three things made them unusable on this pass rather than merely
 * off-style:
 *
 *   1. THEY FILL. `OpPanel` paints `--op77-panel`, `OpRow`'s selected state
 *      paints `--op77-accent`, `OpTabs`' active tab paints it too, `OpGauge` is
 *      twenty filled blocks and `OpScrim` is a full-screen wash. Rule 1 of the
 *      pass is that nothing is filled.
 *   2. THEY ARE YELLOW. Every one of them reads `--op77-accent`, which
 *      `.op-theme-city` on <html> makes Night City yellow. There is no yellow on
 *      this surface.
 *   3. THEY ARE augmented-ui. `--aug-border-bg` is one colour on four sides with
 *      no per-side form, it confiscates the element's two pseudo-elements -- and
 *      this surface needs one of them for the interlace -- and it re-clips on
 *      resize, which for a grid that reflows its column count is a clip storm.
 *
 * WHAT IS NOT A CONTROL DOES NOT GET A FRAME. The detail plate's readouts, the
 * load rule and the separators are lines of type and 1px rules. A closed
 * chamfered frame on this surface means "you can press this", and there are
 * exactly four kinds of thing that can be pressed: a tab, a footer button, a
 * cell, and a row of the per-slot menu.
 *
 * NOTHING ABOUT THE PROTOCOL CHANGED. Same channels, same handle guard, same
 * intents, same payload fields. Only what the player sees.
 *
 * ── CENTRED PASS ────────────────────────────────────────────────────────────
 *
 * THE LAYOUT IS `opx77_inventory`'s, THE STYLE IS OURS. The owner asked for the
 * old resource's positioning back, and what that actually means, read off
 * `opx77_inventory/web/inventory.css`:
 *
 *   * ONE CENTRED PAIR. `.screen` is `inset: 0` with `align-items: center` and
 *     `justify-content: center`; `.frame` is two panels, `align-items:
 *     flex-start`, `gap: --op-space-7`. Both axes, dead centre.
 *   * PANELS ARE A FIXED WIDTH DERIVED FROM THE GRID, not `flex: 1`. Five columns
 *     of a 90px square, seven rows before it scrolls -- see `geometry.ts`.
 *   * THE PAIR SCALES, IT DOES NOT REFLOW. `fit()` is reproduced verbatim,
 *     numbers included.
 *   * THE RIGHT-HAND PLACE IS NEVER EMPTY. With a container open beside the bag
 *     it is that container; with none it is the ground plate, `align-self:
 *     stretch`ed to the bag's height. THIS IS WHY THE OLD ONE READ BETTER: the
 *     bag does not move when a stash opens or closes, because the pair's width
 *     never changes. An `flex: 1 1 0` column that disappears takes the centre
 *     with it.
 *   * THE DETAIL IS A PLATE AT THE POINTER, not a third column. That is what
 *     makes the pair a PAIR: two equal panels about the centre line instead of
 *     three unequal ones with the widest in the middle.
 *
 * WHAT WAS LEFT BEHIND, all of it style rather than geometry: the Night City
 * yellow accent override, the `--op77-panel` fills, the `.plate::before`
 * clip-path plates, the `--op77-line*` hairlines, the SVG ring gauge, the
 * ok/warn/danger wear ramp, the accent-filled hotbar keycap, the glyph-only
 * 32x30 tabs, the `.screen` scrim, the pickup feed (a toast in this runtime) and
 * the drag ghost.
 *
 * THERE IS NO ENCLOSURE ANY MORE. The `clip-path` chamfer, the inset 1px outline
 * and its arete are gone from the panels, and `.bay`/`.bay-inner` collapsed into
 * one element with them -- both existed only to carry those and the interlace.
 * A cell keeps its frame: a cell is a control.
 */

const TIMEOUT_MS = 16000

const handle = ref<Handle | null>(null)
const open = ref(false)

const config = ref<ScreenConfig>({
  labels: {},
  hotbar: [],
  openKey: '',
  drops: false,
  defaultWeight: 0
})
const tabs = ref<TabSpec[]>([])

/* `shallowRef` for the containers: each is replaced whole on every push, and a
   deep reactive proxy over a Map of two hundred stacks is work nobody reads. */
const primary = shallowRef<Container | null>(null)
const secondary = shallowRef<Container | null>(null)

/* The catalogue arrives in parts and is only adopted on the part marked `done`:
   a half-arrived catalogue drawn over a whole one is every second item losing
   its name. */
const catalog = shallowRef<Map<string, CatalogEntry>>(new Map())
let incoming: Map<string, CatalogEntry> | null = null

const nearby = ref<NearbyPlayer[]>([])
const broken = reactive(new Set<string>())

const tab = ref('')
const busy = ref(false)
const status = ref('')

/** Which cell the pointer is over, and where the pointer was when it arrived.
    The detail plate follows the pointer now rather than sitting in a column, so
    the coordinates are part of the hover and not a separate listener: a
    `pointermove` bound for the whole time the screen is up, at 60fps over forty
    cells, to place a plate that only moves between cells anyway. */
const hovered = reactive({ container: 0, slot: 0, x: 0, y: 0 })

/** The drag in flight: where it came from, the cell it is over now, and whether
    it is over the ground instead of a cell. */
const drag = reactive({
  container: 0,
  slot: 0,
  overContainer: 0,
  overSlot: 0,
  overGround: false,
  active: false
})

/** The cell whose menu is up, and where to draw it. */
const menu = reactive({ container: 0, slot: 0, x: 0, y: 0, open: false })

/** The split step: how many units of the chosen stack to take out. */
/* The count dialog. `mode` says what its confirm does: split a stack, give part
   of it to `target`, or drop part of it. Give and drop moved the WHOLE stack in
   one click -- "give one of twenty" meant splitting first -- so a stack of more
   than one now asks how many, and that question is also the confirm step. */
const split = reactive({
  container: 0,
  slot: 0,
  count: 1,
  max: 1,
  open: false,
  mode: 'split' as 'split' | 'give' | 'drop',
  target: 0
})

let release: (() => void) | undefined
let pointerBound = false

/** One empty list for the secondary grid's props. An inline `[]` is a NEW array on
    every render of this view -- every cell the pointer crosses mid-drag -- and a new
    prop identity re-renders the whole secondary grid each time. */
const NONE: string[] = []

/** A label Lua sent, or the fallback -- never the key. A container kind with no
    word of its own (`character`, a searched bag) used to print as the raw kind in
    the eyebrow. */
function label(key: string, fallback = ''): string {
  return config.value.labels[key] || fallback
}

/** Escape closes the innermost thing open: the split dialog, then the slot card,
    and only then the inventory. It closed everything from inside a dialog. */
function onEscape(): void {
  if (split.open) split.open = false
  else if (menu.open) closeMenu()
  else close()
}

function mine(payload: Payload): boolean {
  return handle.value !== null && payload.handle === handle.value
}

/* -- talking to Lua ------------------------------------------------------------
   Everything below carries the handle and an INTENT. `ask` is the round trip the
   bridge's rpc provides; `tell` is fire and forget for the things whose answer is
   the next push. */

function tell(action: string, payload: Payload = {}): void {
  if (handle.value === null) return
  send('opx:inventory:request', { handle: handle.value, action, payload })
}

async function ask(action: string, payload: Payload = {}): Promise<Payload | null> {
  if (handle.value === null) return null
  busy.value = true
  status.value = ''
  try {
    return await request(
      'opx:inventory:request',
      { handle: handle.value, action, payload },
      { timeoutMs: TIMEOUT_MS }
    )
  } catch (error) {
    // Every refusal the SERVER makes is a toast Lua raised, so the page
    // does not render one: it only says that the round trip failed or never came
    // back, in words the open spec carried in the player's language. A raw code
    // is never put on screen.
    // AN ANSWERED REFUSAL IS NOT ONE OF THOSE. It carries the server's own code,
    // and the server has toasted its sentence: drawing "That did not work." under
    // it as well was the same refusal said twice, the second time with no reason,
    // and it stayed on screen through every action that succeeded after it.
    const key = error instanceof BridgeError ? error.localeKey : ''
    const timedOut = key === 'error.rpc_timeout' || key === 'timeout'
    const unanswered = key === '' || key === 'error.rpc_failed'
    if (timedOut || unanswered) status.value = label(timedOut ? 'timeout' : 'failed')
    return null
  } finally {
    busy.value = false
  }
}

/* -- the view ------------------------------------------------------------------ */

const currentTab = computed(() => {
  if (tabs.value.length === 0) return ''
  if (tabs.value.some((spec) => spec.key === tab.value)) return tab.value
  return tabs.value[0].key
})

/** The categories the active tab gathers. A `rest` tab gathers what no other
    tab names, which is computed here because only the page knows the full set. */
const activeCategories = computed<string[]>(() => {
  const spec = tabs.value.find((entry) => entry.key === currentTab.value)
  if (!spec) return []
  if (!spec.rest) return spec.categories
  const named = new Set<string>()
  for (const other of tabs.value) {
    if (other.rest) continue
    for (const category of other.categories) named.add(category)
  }
  const rest = new Set<string>()
  for (const entry of catalog.value.values()) {
    if (!named.has(entry.category)) rest.add(entry.category)
  }
  // `misc` is the catalogue's own default category, so a rest tab always holds it.
  rest.add('misc')
  return Array.from(rest)
})

function containerById(id: number): Container | null {
  if (primary.value && primary.value.id === id) return primary.value
  if (secondary.value && secondary.value.id === id) return secondary.value
  return null
}

function stackAt(containerId: number, slot: number) {
  const container = containerById(containerId)
  if (!container) return null
  return container.bySlot.get(slot) ?? null
}

/** The stack the card's told half describes: THE ONE THAT WAS RIGHT-CLICKED.

    It followed the pointer, and the owner asked for the right-click instead. That
    is the better rule and not just a preference: a plate that opens on hover opens
    forty times while you cross a grid, it sits over the cell you are aiming at,
    and it is in the way exactly when you are moving something. Asked for, it is
    never in the way -- and it is now the HEAD OF THE MENU rather than a second
    box beside it, so one gesture gives one box saying both what the thing is and
    what can be done with it.

    Still nothing during a drag: the pointer is carrying a stack, and the menu is
    closed then anyway. */
const detail = computed(() => {
  if (drag.active || !menu.open) return null
  const stack = stackAt(menu.container, menu.slot)
  if (!stack) return null
  const entry = catalog.value.get(stack.name)
  return {
    stack,
    entry,
    label: labelOf(stack, entry, label('unknown', '?')),
    description: entry ? entry.description : '',
    weight: grams(weightOf(stack, entry, config.value.defaultWeight), config.value),
    ammo: ammoOf(stack),
    serial: serialOf(stack),
    wear: durabilityOf(stack)
  }
})

function titleOf(container: Container | null, fallbackKey: string): string {
  if (!container) return label(fallbackKey)
  if (container.title) return container.title
  return label(container.kind, label(fallbackKey))
}

const primaryLoad = computed(() =>
  primary.value ? loadPercent(primary.value.weight, primary.value.maxWeight) : 0
)
const secondaryLoad = computed(() =>
  secondary.value ? loadPercent(secondary.value.weight, secondary.value.maxWeight) : 0
)

function loadText(container: Container | null): string {
  if (!container) return ''
  return `${grams(container.weight, config.value)} / ${grams(container.maxWeight, config.value)}`
}

/* THE LOAD RULE RUNS RED -> LIT RED -> WHITE. Not red-amber-red: red is the voice
   of the whole surface, so a red bar inside a red frame under a red heading is
   not a warning, it is camouflage. White is the only mark on this screen that is
   not part of the red family, which is what makes a full bag impossible to miss. */
function toneFor(percent: number): '' | 'high' | 'full' {
  if (percent >= 95) return 'full'
  if (percent >= 75) return 'high'
  return ''
}

/* TECHNICAL FILLER THAT IS TRUE. The reference prints a block of real-looking
   machine text under a real menu; this prints the two numbers the surface
   actually knows and was not saying -- how many of a container's slots hold
   something, out of how many it has. `bySlot` is sparse by construction, so its
   size IS the occupied count. Nothing is invented and nothing is asked for. */
function occupancy(container: Container | null): string {
  if (!container) return ''
  const used = String(container.bySlot.size).padStart(2, '0')
  return `${used}/${String(container.slots).padStart(2, '0')}`
}

/* -- THE FIT, taken from opx77_inventory ---------------------------------------
   The old resource centred a fixed-size pair of panels and scaled the PAIR to
   fit whatever surface it was given, rather than reflowing it. Its `fit()`:

     base  = clamp(0.72, innerHeight / 1080, 1.5)
     scale = min(base, innerWidth * 0.92 / width, innerHeight * 0.9 / height)

   Reproduced verbatim, including the numbers. It is the reason the old layout
   read better: the grid is always five columns of the same size square, at any
   resolution, so the bag a player learns the shape of never changes shape. A
   reflowing grid re-columns itself on every window size and on the secondary
   panel appearing, and a slot is then never in the same place twice.

   `offsetWidth` is the LAYOUT size and is unaffected by the transform that reads
   this, so there is no feedback loop between the two. */
const frame = ref<HTMLElement | null>(null)
const scale = ref(1)

let frameObserver: ResizeObserver | null = null

function measureFit(): void {
  const element = frame.value
  if (!element) return
  const width = element.offsetWidth || 1
  const height = element.offsetHeight || 1
  const base = Math.max(0.72, Math.min(1.5, window.innerHeight / 1080))
  scale.value = Math.min(
    base,
    (window.innerWidth * 0.92) / width,
    (window.innerHeight * 0.9) / height
  )
}

/* -- THE CARD'S PLACE, taken from opx77_inventory ------------------------------
   It was a tooltip at the pointer there, not a column, and that is the single
   biggest reason the old arrangement was better balanced: the centred pair is
   TWO panels about the centre line instead of three unequal ones with the widest
   in the middle. Its `place()` offsets by 14px, flips to the other side of the
   pointer rather than off-screen, and never goes within 8px of an edge.

   ONE BOX AND NOT TWO. The plate and the per-slot menu used to open together as
   two boxes either side of the pointer, and one right-click read as two things
   happening. They are ONE CARD now -- what the thing is on top, what can be done
   with it under it -- so there is one place to look and one box to place. It
   hangs down-right of the pointer and flips on either axis at an edge.
   ========================================================================== */
/** The card's own width, in one place: the stylesheet lays it out and the
    placement below has to know how wide it is before it has been measured. */
const CARD_WIDTH = 200

const card = ref<HTMLElement | null>(null)
const cardAt = reactive({ left: 0, top: 0 })

function placeCard(): void {
  const node = card.value
  if (!node) return
  const width = node.offsetWidth || CARD_WIDTH
  const height = node.offsetHeight
  let left = menu.x + 14
  let top = menu.y + 14
  // Flip to the other side of the pointer rather than run off the edge, and only
  // then slide back inside: a card that is clamped without flipping ends up under
  // the cursor it was opened from.
  if (left + width > window.innerWidth - 8) left = menu.x - 14 - width
  if (top + height > window.innerHeight - 8) top = menu.y - 14 - height
  cardAt.left = Math.max(8, Math.min(left, window.innerWidth - 8 - width))
  cardAt.top = Math.max(8, Math.min(top, window.innerHeight - 8 - height))
}

/* -- the drag ------------------------------------------------------------------
   Pointer events and not the browser's own drag: a `dragstart` inside a CEF page
   carries an image nothing can style and fires no move events over a scrolling
   grid. What is tracked here is only where the pointer went; the MOVE it turns
   into is Lua's to accept. */

function cellUnder(x: number, y: number): { container: number; slot: number } | null {
  const element = document.elementFromPoint(x, y)
  if (!element) return null
  const cell = element.closest('[data-slot]')
  if (!cell) return null
  const owner = cell.closest('[data-container]')
  if (!owner) return null
  const slot = Number(cell.getAttribute('data-slot'))
  const container = Number(owner.getAttribute('data-container'))
  if (!Number.isFinite(slot) || !Number.isFinite(container)) return null
  return { container, slot }
}

/** Whether the pointer is over the ground plate, which is what stands in the
    right-hand place when no container is open beside the bag. */
function groundUnder(x: number, y: number): boolean {
  const element = document.elementFromPoint(x, y)
  return element !== null && element.closest('[data-ground]') !== null
}

function onPointerMove(event: PointerEvent): void {
  if (!drag.active) return
  const at = cellUnder(event.clientX, event.clientY)
  drag.overContainer = at ? at.container : 0
  drag.overSlot = at ? at.slot : 0
  drag.overGround = at === null && groundUnder(event.clientX, event.clientY)
}

function endDrag(): void {
  drag.active = false
  drag.container = 0
  drag.slot = 0
  drag.overContainer = 0
  drag.overSlot = 0
  drag.overGround = false
}

function onPointerUp(event: PointerEvent): void {
  if (!drag.active) return
  const at = cellUnder(event.clientX, event.clientY)
  const onGround = at === null && groundUnder(event.clientX, event.clientY)
  const from = { container: drag.container, slot: drag.slot }
  const fromBag = primary.value !== null && from.container === primary.value.id
  endDrag()
  unbindPointer()

  // The ground takes a stack out of the bag and nothing else -- a trunk cannot
  // be emptied onto the floor from across the street. It is the SAME `drop`
  // intent the per-slot menu sends, with the same one field, so the ground plate
  // is a second route to an existing action and not a new one.
  if (onGround) {
    if (fromBag) void ask('drop', { slot: from.slot })
    return
  }

  if (!at) return
  if (at.container === from.container && at.slot === from.slot) return

  // An INTENT: two slots and two containers. Not a result, not a count, and not
  // a new weight -- Lua decides whether this is a move, a stack or a swap.
  void ask('move', {
    from: from.container,
    fromSlot: from.slot,
    to: at.container,
    toSlot: at.slot
  })
}

/** A drag whose release never reached this page -- the game took focus, the window
    lost it, the engine cancelled the pointer -- is DROPPED, not left armed. Armed, the
    next `pointerup` anywhere on the screen sent a `move` (or a `drop`, over the
    ground) from the stale source slot. */
function cancelDrag(): void {
  endDrag()
  unbindPointer()
}

function bindPointer(): void {
  if (pointerBound) return
  pointerBound = true
  window.addEventListener('pointermove', onPointerMove)
  window.addEventListener('pointerup', onPointerUp)
  window.addEventListener('pointercancel', cancelDrag)
  window.addEventListener('blur', cancelDrag)
}

function unbindPointer(): void {
  if (!pointerBound) return
  pointerBound = false
  window.removeEventListener('pointermove', onPointerMove)
  window.removeEventListener('pointerup', onPointerUp)
  window.removeEventListener('pointercancel', cancelDrag)
  window.removeEventListener('blur', cancelDrag)
}

function onGrab(containerId: number, slot: number, native: PointerEvent): void {
  // The primary button only: a right- or middle-button drag from one cell to another
  // used to send a `move` like a left one.
  if (busy.value || native.button !== 0) return
  closeMenu()
  drag.active = true
  drag.container = containerId
  drag.slot = slot
  drag.overContainer = containerId
  drag.overSlot = slot
  bindPointer()
  // A capture on the cell would be lost the moment the grid re-renders the
  // window under the pointer, so the listeners live on the window instead.
}

function onHover(containerId: number, slot: number | null, native?: MouseEvent): void {
  hovered.container = slot === null ? 0 : containerId
  hovered.slot = slot ?? 0
  if (native) {
    hovered.x = native.clientX
    hovered.y = native.clientY
  }
}

/* -- the per-slot menu --------------------------------------------------------- */

function openMenu(containerId: number, slot: number, native: MouseEvent): void {
  const stack = stackAt(containerId, slot)
  if (!stack) return
  menu.container = containerId
  menu.slot = slot
  menu.x = native.clientX
  menu.y = native.clientY
  menu.open = true
  // THE GIVE LIST IS ASKED FOR AGAIN EVERY TIME THE CARD OPENS. It was asked
  // once, when the inventory opened: somebody who walked up afterwards was
  // never on it, and somebody who had left stayed on it until a give to them
  // was refused. The answer is the next `nearby` push, a frame or two later.
  // Only for the bag: a trunk's card has no give list.
  if (containerId === primary.value?.id) tell('nearby')
  // Placed roughly here straight away and refined once the card has a measured
  // size. Without this the first frame renders it at 0,0, because `placeCard`
  // cannot flip a box it has not measured yet.
  cardAt.left = native.clientX + 14
  cardAt.top = native.clientY + 14
}

function closeMenu(): void {
  menu.open = false
}

const menuStack = computed(() => (menu.open ? stackAt(menu.container, menu.slot) : null))

const menuEntry = computed(() => {
  const stack = menuStack.value
  return stack ? catalog.value.get(stack.name) : undefined
})

const isBag = computed(() => menu.container !== 0 && menu.container === primary.value?.id)

function doUse(): void {
  const slot = menu.slot
  closeMenu()
  void ask('use', { slot })
}

/** Where a nearby player stands, as the give list says it: `To your left · 1.2 m`,
    with the language's decimal mark. Never a name -- the server sends none. */
function whereIs(person: { side: string; distance: number }): string {
  const metres = person.distance.toFixed(1).replace('.', label('decimal', '.'))
  const distance = `${metres} ${label('m', 'm')}`
  const keys: Record<string, string> = {
    ahead: 'sideAhead',
    behind: 'sideBehind',
    left: 'sideLeft',
    right: 'sideRight'
  }
  const side = keys[person.side] ? label(keys[person.side]) : ''
  return side ? `${side} · ${distance}` : distance
}

/** Opens the count dialog to give or drop part of a stack, or acts at once on a
    single item, where there is nothing to choose. */
function askCount(mode: 'give' | 'drop', target: number): boolean {
  const stack = menuStack.value
  if (!stack || stack.count < 2) return false
  split.container = menu.container
  split.slot = menu.slot
  split.max = stack.count
  split.count = 1
  split.mode = mode
  split.target = target
  split.open = true
  closeMenu()
  return true
}

function doDrop(): void {
  if (askCount('drop', 0)) return
  const slot = menu.slot
  closeMenu()
  void ask('drop', { slot })
}

function doGive(playerId: number): void {
  if (askCount('give', playerId)) return
  const slot = menu.slot
  closeMenu()
  void ask('give', { target: playerId, slot })
}

function openSplit(): void {
  const stack = menuStack.value
  if (!stack || stack.count < 2) return
  split.container = menu.container
  split.slot = menu.slot
  split.max = stack.count - 1
  split.count = Math.max(1, Math.floor(stack.count / 2))
  split.mode = 'split'
  split.target = 0
  split.open = true
  closeMenu()
}

function doSplit(): void {
  const { container, slot, count, mode, target } = split
  split.open = false
  if (mode === 'give') void ask('give', { target, slot, count })
  else if (mode === 'drop') void ask('drop', { slot, count })
  else void ask('split', { container, slot, count })
}

/** The count dialog's title and confirm, by what it is for. */
const countTitle = computed(() =>
  split.mode === 'give' ? label('giveHowMany') : split.mode === 'drop' ? label('dropHowMany') : label('split')
)
const countConfirm = computed(() =>
  split.mode === 'give' ? label('give') : split.mode === 'drop' ? label('drop') : label('split')
)

function stepSplit(delta: number): void {
  split.count = Math.max(1, Math.min(split.max, split.count + delta))
}

function doSort(containerId: number, mode: 'weight' | 'name'): void {
  void ask('sort', { container: containerId, mode })
}

function closeSecondary(): void {
  void ask('closeSecondary')
}

function close(): void {
  send('opx:inventory:dismiss', { handle: handle.value })
}

/* -- what Lua pushes ----------------------------------------------------------- */

function applyConfig(payload: unknown): void {
  config.value = readConfig(payload)
  const spec = readTabs(table(payload).labels)
  if (spec.length > 0) tabs.value = spec
}

function blank(): void {
  open.value = false
  primary.value = null
  secondary.value = null
  nearby.value = []
  status.value = ''
  busy.value = false
  endDrag()
  unbindPointer()
  closeMenu()
  split.open = false
  hovered.container = 0
  hovered.slot = 0
}

useBridge('opx:inventory:config', (payload) => {
  guard('inventory:config', () => applyConfig(payload), undefined)
})

useBridge('opx:inventory:catalog', (payload) => {
  guard(
    'inventory:catalog',
    () => {
      if (bool(payload.first) || incoming === null) incoming = new Map()
      const entries = table(payload.entries)
      for (const name of Object.keys(entries)) {
        incoming.set(name, readCatalogEntry(entries[name]))
      }
      if (!bool(payload.done)) return
      catalog.value = incoming
      incoming = null
    },
    undefined
  )
})

useBridge('opx:inventory:open', (payload) => {
  guard(
    'inventory:open',
    () => {
      const given = payload.handle
      if (typeof given !== 'string' || given === '') return
      release?.()
      blank()
      handle.value = given
      applyConfig(payload.config)
      primary.value = readContainer(payload.primary)
      secondary.value = payload.secondary === false ? null : readContainer(payload.secondary)
      tab.value = tabs.value.length > 0 ? tabs.value[0].key : ''
      open.value = true
      release = acquireFocus({ id: 'inventory', onEscape })
      // The nearby list is asked for, not assumed: who is close enough to be
      // handed something is a fact about the world, and the world is Lua's.
      tell('nearby')
    },
    undefined
  )
})

useBridge('opx:inventory:update', (payload) => {
  guard(
    'inventory:update',
    () => {
      if (!mine(payload)) return
      const container = readContainer(payload.container)
      if (!container) return
      if (primary.value && container.id === primary.value.id) primary.value = container
      else if (secondary.value && container.id === secondary.value.id) secondary.value = container
    },
    undefined
  )
})

useBridge('opx:inventory:secondary', (payload) => {
  guard(
    'inventory:secondary',
    () => {
      if (!mine(payload)) return
      secondary.value = payload.container === false ? null : readContainer(payload.container)
    },
    undefined
  )
})

useBridge('opx:inventory:nearby', (payload) => {
  guard(
    'inventory:nearby',
    () => {
      if (!mine(payload)) return
      nearby.value = readNearby(payload.players)
    },
    undefined
  )
})

useBridge('opx:inventory:close', (payload) => {
  guard(
    'inventory:close',
    () => {
      if (payload.handle !== undefined && !mine(payload)) return
      handle.value = null
      blank()
      release?.()
      release = undefined
    },
    undefined
  )
})

/* The fit is re-measured whenever the pair's LAYOUT size changes -- which covers
   the window resizing, the secondary panel appearing and going, and the screen
   opening at all -- and not on a timer. A `ResizeObserver` on the frame catches
   the first two; the third is the `watch` on `open` below, because a `v-if`ed
   frame has no box to observe until it exists. */
onMounted(() => {
  if (typeof ResizeObserver === 'function') {
    frameObserver = new ResizeObserver(measureFit)
  }
  window.addEventListener('resize', measureFit)
})

watch(open, (up) => {
  void nextTick(() => {
    if (up && frame.value) {
      frameObserver?.observe(frame.value)
      measureFit()
    } else {
      frameObserver?.disconnect()
    }
  })
})

/* The card is placed after it has rendered, because the flip at the edges needs
   its measured size. Watching the MENU rather than `detail` itself: a computed
   returning a fresh object every time would fire this on every push of a
   container that has nothing to do with what was right-clicked. */
watch(
  [() => menu.open, () => menu.container, () => menu.slot, () => menu.x, () => menu.y],
  () => {
    void nextTick(placeCard)
  }
)

onUnmounted(() => {
  unbindPointer()
  frameObserver?.disconnect()
  frameObserver = null
  window.removeEventListener('resize', measureFit)
  release?.()
})

// Last: Lua takes this as permission to send the configuration and the catalogue,
// and a payload arriving before the channels above are bound is simply lost.
try {
  send('opx:inventory:ready', {})
} catch (error) {
  report(error, 'inventory:ready')
}

</script>

<template>
  <div class="room" :class="{ open, dragging: drag.active }">
    <!-- `.screen` of the old resource: the whole thing centred on both axes, and
         no scrim behind it. -->
    <div v-if="open" class="screen">
      <!-- `.frame`: the pair. It carries the perspective, so the panels inside it
           are the planes that tilt and they share ONE vanishing point at the
           centre of the pair. It also carries the fit, as the old one did. -->
      <div ref="frame" class="frame" :style="{ transform: `scale(${scale})` }">
        <!-- THE BAG. `data-container` is what the drag resolver reads off the DOM
             to name the container a cell belongs to. -->
        <section
          class="panel lead"
          :style="{ width: `${GRID_WIDTH}px` }"
          :data-container="primary ? primary.id : 0"
        >
          <header class="head">
            <div class="head-text">
              <span class="eyebrow">{{ label('bag') }}</span>
              <h1 class="op-truncate">{{ titleOf(primary, 'bag') }}</h1>
            </div>
            <!-- The key the player actually has, rebinds included: Lua reads it
                 back off the host at send time rather than trusting the config. -->
            <kbd v-if="config.openKey" class="cap" data-augmented-ui="tr-clip border">{{ config.openKey }}</kbd>
          </header>

          <nav v-if="tabs.length" class="tabs">
            <button
              v-for="spec in tabs"
              :key="spec.key"
              type="button"
              class="tab"
              data-augmented-ui="tr-clip border"
              :class="{ on: spec.key === currentTab }"
              @click="tab = spec.key"
            >
              {{ spec.label }}
            </button>
          </nav>

          <div class="meter">
            <span class="cap-mono">{{ label('weight') }}</span>
            <span class="rule" :class="toneFor(primaryLoad)">
              <i :style="{ width: `${primaryLoad}%` }" />
            </span>
            <span class="figure">{{ loadText(primary) }}</span>
            <span class="figure quiet">{{ occupancy(primary) }}</span>
          </div>

          <InventoryGrid
            v-if="primary"
            :container="primary"
            :catalog="catalog"
            :config="config"
            :categories="activeCategories"
            :hotbar="config.hotbar"
            :selected="0"
            :over="drag.overContainer === primary.id ? drag.overSlot : 0"
            :dragging="drag.container === primary.id ? drag.slot : 0"
            :broken="broken"
            @grab="(slot, native) => onGrab(primary!.id, slot, native)"
            @open="(slot, native) => openMenu(primary!.id, slot, native)"
            @hover="(slot, native) => onHover(primary!.id, slot, native)"
            @broke="(name) => broken.add(name)"
          />

          <footer class="foot">
            <button
              type="button"
              class="row op-label grow"
              data-augmented-ui="tr-clip border"
              :class="{ off: !primary || busy }"
              :disabled="!primary || busy"
              @click="primary && doSort(primary.id, 'weight')"
            >
              {{ label('sortWeight') }}
            </button>
            <button
              type="button"
              class="row op-label grow"
              data-augmented-ui="tr-clip border"
              :class="{ off: !primary || busy }"
              :disabled="!primary || busy"
              @click="primary && doSort(primary.id, 'name')"
            >
              {{ label('sortName') }}
            </button>
            <button
              type="button"
              class="row op-label grow"
              data-augmented-ui="tr-clip border"
              @click="close"
            >
              {{ label('close') }}
            </button>
          </footer>
        </section>

        <!-- THE RIGHT-HAND PLACE, and it is never empty: that is what keeps the
             bag still when a stash opens or closes. Whatever is open beside the
             bag when there is something, the ground when there is not. -->
        <section
          class="panel trail"
          :style="{ width: `${GRID_WIDTH}px` }"
          :data-container="secondary ? secondary.id : 0"
        >
          <template v-if="secondary">
            <header class="head">
              <div class="head-text">
                <span class="eyebrow">{{ label(secondary.kind === 'drop' ? 'ground' : secondary.kind) }}</span>
                <h1 class="op-truncate">{{ titleOf(secondary, 'stash') }}</h1>
              </div>
            </header>

            <div class="meter">
              <span class="cap-mono">{{ label('weight') }}</span>
              <span class="rule" :class="toneFor(secondaryLoad)">
                <i :style="{ width: `${secondaryLoad}%` }" />
              </span>
              <span class="figure">{{ loadText(secondary) }}</span>
              <span class="figure quiet">{{ occupancy(secondary) }}</span>
            </div>

            <InventoryGrid
              :container="secondary"
              :catalog="catalog"
              :config="config"
              :categories="NONE"
              :hotbar="NONE"
              :selected="0"
              :over="drag.overContainer === secondary.id ? drag.overSlot : 0"
              :dragging="drag.container === secondary.id ? drag.slot : 0"
              :broken="broken"
              @grab="(slot, native) => onGrab(secondary!.id, slot, native)"
              @open="(slot, native) => openMenu(secondary!.id, slot, native)"
              @hover="(slot, native) => onHover(secondary!.id, slot, native)"
              @broke="(name) => broken.add(name)"
            />

            <footer class="foot">
              <button
                type="button"
                class="row op-label grow"
                data-augmented-ui="tr-clip border"
                :class="{ off: busy }"
                :disabled="busy"
                @click="doSort(secondary!.id, 'weight')"
              >
                {{ label('sortWeight') }}
              </button>
              <button
                type="button"
                class="row op-label grow"
                data-augmented-ui="tr-clip border"
                @click="closeSecondary"
              >
                {{ label('close') }}
              </button>
            </footer>
          </template>

          <!-- The ground. No title and no tools, exactly as the old resource's
               `drawGround` drew it: "nothing but the drop zone beside the bag".
               It is a CONTROL -- you drop onto it -- so it is the one thing here
               besides a cell that still carries a closed frame. -->
          <div
            v-else
            class="ground"
            data-augmented-ui="tr-clip bl-clip border"
            :class="{ over: drag.overGround, armed: config.drops }"
            :data-ground="config.drops ? 'drop' : undefined"
          >
            <span class="ground-word">
              {{ config.drops ? label('dropZone') : label('ground', '') }}
            </span>
            <span v-if="config.drops" class="ground-hint">{{ label('groundHint', '') }}</span>
          </div>
        </section>
      </div>
    </div>

    <!-- A FAILURE READS WHITE AND HEAVIER, never red: a red line among red
         readouts says nothing. It sat in the detail column, which is now the head of
         a card that is not on screen most of the time and never during the
         request that failed -- so it is anchored under the pair instead, where the player is
         already looking. -->
    <p v-if="open && status" class="status">{{ status }}</p>

    <!-- THE SLOT CARD -- what the thing is, then what can be done with it, in ONE
         box at the pointer. Positioned in viewport pixels and outside the scaled
         pair, so the fit and the tilt leave it alone. -->
    <div v-if="menu.open && menuStack" class="menu-layer" @pointerdown.self="closeMenu">
      <div
        ref="card"
        class="menu"
        :style="{ left: `${cardAt.left}px`, top: `${cardAt.top}px` }"
      >
        <div v-if="detail" class="told">
          <div class="told-top">
            <span class="told-name">{{ detail.label }}</span>
            <span v-if="detail.stack.count > 1" class="told-times">
              {{ detail.stack.count }}&times;
            </span>
          </div>

          <p v-if="detail.description" class="prose">{{ detail.description }}</p>

          <div class="fact">
            <span class="cap-mono">{{ label('weight') }}</span>
            <span class="value op-value op-truncate">{{ detail.weight }}</span>
          </div>
          <div v-if="detail.ammo >= 0" class="fact">
            <span class="cap-mono">{{ label('ammo') }}</span>
            <span class="value op-value op-truncate">{{ detail.ammo }}</span>
          </div>
          <div v-if="detail.serial" class="fact">
            <span class="cap-mono">{{ label('serial') }}</span>
            <span class="value op-value op-truncate">{{ detail.serial }}</span>
          </div>

          <div v-if="detail.wear >= 0" class="meter stack">
            <span class="cap-mono">{{ label('condition') }}</span>
            <span
              class="rule"
              :class="detail.wear < 0.25 ? 'full' : detail.wear < 0.6 ? 'high' : ''"
            >
              <i :style="{ width: `${detail.wear * 100}%` }" />
            </span>
          </div>
        </div>

        <div class="list">
          <button
            v-if="isBag && menuEntry?.usable"
            type="button"
            class="row op-label"
            :class="{ off: busy }"
            :disabled="busy"
            @click="doUse"
          >
            {{ label('use') }}
          </button>
          <button
            v-if="menuStack.count > 1"
            type="button"
            class="row op-label"
            :class="{ off: busy }"
            :disabled="busy"
            @click="openSplit"
          >
            {{ label('split') }}
          </button>
          <!-- `droppable` is the server's own answer, carried on the catalogue
               entry, and the row is HIDDEN rather than disabled: a greyed-out
               Drop invites the question "why", and the honest answer -- a pile
               is memory-only, so dropping eddies would delete them at the next
               restart -- does not fit on a menu row. Dragging onto the ground
               zone is still offered and still refused by the server, with a
               toast that says so. -->
          <button
            v-if="isBag && config.drops && menuEntry?.droppable !== false"
            type="button"
            class="row op-label"
            :class="{ off: busy }"
            :disabled="busy"
            @click="doDrop"
          >
            {{ label('drop') }}
          </button>

          <template v-if="isBag">
            <div class="sep op-eyebrow">{{ label('giveTo') }}</div>
            <button
              v-for="person in nearby"
              :key="person.id"
              type="button"
              class="row op-label"
              :class="{ off: busy }"
              :disabled="busy"
              @click="doGive(person.id)"
            >
              <span class="row-label op-truncate">{{ whereIs(person) }}</span>
              <span class="row-value op-value">#{{ person.id }}</span>
            </button>
            <div v-if="!nearby.length" class="sep op-eyebrow">{{ label('nobody') }}</div>
          </template>
        </div>
      </div>
    </div>

    <!-- The split step. A number the player chooses; Lua still checks it. -->
    <div v-if="split.open" class="menu-layer" @pointerdown.self="split.open = false">
      <div class="dialog">
        <header class="head">
          <h2>{{ countTitle }}</h2>
        </header>
        <div class="stepper">
          <button type="button" class="row op-label" @click="stepSplit(-1)">&minus;</button>
          <span class="count">{{ split.count }}</span>
          <button type="button" class="row op-label" @click="stepSplit(1)">+</button>
        </div>
        <!-- TRUE, and the surface already knew it: the most this stack can give
             up is one unit less than it holds. -->
        <p class="hint">1 &ndash; {{ split.max }}</p>
        <footer class="foot">
          <button type="button" class="row op-label grow" @click="split.open = false">
            {{ label('cancel') }}
          </button>
          <button type="button" class="row op-label grow on" @click="doSplit">
            {{ countConfirm }}
          </button>
        </footer>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   DESIGN PASS 02, CENTRED, NO ENCLOSURE.

   The type, the three reds plus the hot rung, the black shadows and the 9-slice
   cell frames are all unchanged. What changed is where things sit and what is
   drawn around them:

     * THE LAYOUT IS `opx77_inventory`'s. See the block at the top of the script
       for what was taken and what was left behind.
     * THE CONTAINER FRAME IS GONE. No `clip-path`, no inset outline, no arete. A
       panel is a column of instruments sitting loose on the gameplay plane, which
       is the call the owner has now made on two HUD blocks and the ALT target,
       and which the old resources also made by drawing no enclosure at all.
     * THE INTERLACE IS GONE WITH IT, and is NOT replaced. Its whole justification
       (rule 9) was that it stops an unfilled FRAME reading as a page floating in
       the air -- it was texture for a surface. With no frame there is no surface
       for it to be on, and a 1px-per-3px gradient over a bounded region draws its
       own boundary: it would paint back the exact rectangle the enclosure was
       just removed to get rid of, which is the argument the HUD agent made for
       the unenclosed clusters. Nothing was put in its place because nothing is
       missing: forty chamfered 1px cell outlines are denser technical texture
       than the gradient ever was, and the grid is where the eye actually is.
     * THE TILT IS NOW A V, NOT TWO RECEDING EDGES. Reasoned at `.frame` below.
     * TWO ELEMENTS ARE FILLED AGAIN, AND EXACTLY TWO. The owner asked for a
       background on the inventory slots "and the drop one too", and then for
       that background to be red -- the cells, in `InventorySlot.vue`, and
       `.ground` here. Both get a dark low-alpha plate under the outline so an
       item picture and a stack count survive a bright street, and both take that
       plate from this surface's own red rather than from a panel token: #1c0809
       and #4a1519 are `--red-idle`'s rgb at 12% and 32%, which is red as a BLACK
       and not a red panel -- a saturated one would swallow the icons the fill
       was added to rescue. Nothing else on the surface was touched. The full
       argument is at the top of `InventorySlot.vue`; the sizing argument for
       this file's one plate is at `.ground` below. The no-fill rule stands
       everywhere else and this is not the precedent for relaxing it.

   TWO THINGS THE PASS LEFT UNFINISHED, and both are settled here:

     * THE SURFACE NOW HAS ONE PALETTE, AT ONE ADDRESS. The ink, the separation
       shadow, the bloom, the resting lettering red and the unfilled part of a
       rule were literals repeated eighteen times across this file and
       `InventorySlot.vue` -- which is eighteen chances for the grid and the
       panel around it to drift apart, and the drift the token file was written
       to stop, reintroduced one surface lower down. They are five custom
       properties on `.room` now. A custom property INHERITS across a component
       boundary where a scoped selector does not, so the cell reads the surface's
       voice without a single `:deep()`; this is HudRoot.vue's mechanism and it
       is used here for HudRoot.vue's reason.
     * THE LOAD RULE IS SEGMENTED. It was the last readout on the surface still
       drawn as a continuous fill, which the token file argues against and the
       HUD's vitals column had already acted on: over gameplay a smooth bar has
       no edge to read against a moving backdrop, and a count of lit divisions is
       read without being looked at. It is a MASK rather than an overlay, so the
       notches are the street showing through and not a colour painted on -- see
       `.rule`, where the mechanism and its fallback are set out.
   ========================================================================== */

/* --- THE RED --------------------------------------------------------------
   Local to this surface, as the menu's is: `.op-theme-city` on <html> makes
   `--op77-accent` Night City yellow for every surface, and there is no yellow
   here. Three steps dim -> deep -> lit, plus the lit arete, plus the HOT rung.

   `--red-hot` is the alarm, and it is red: an alarm stays in the hue and climbs
   in intensity rather than leaving for white. `--op-text` is now ONLY
   legibility -- a stack count, a data value, the label under the pointer --
   and never a meaning.

   THE LADDER ITSELF IS GONE FROM HERE: the six rungs this file used to declare
   are `design-system/tokens.css` now, and the grid and the cell read them from
   the document rather than from this subtree. What is left below is the two
   rung that is TRUE OF THIS SURFACE and of nothing else. */
.room {

  /* ONE RUNG THE DESIGN SYSTEM HAS NO NAME FOR, because only this surface has
     the shape. `--red-track` is the unfilled part of a rule. The load bar in a panel head,
     the condition bar in the detail plate and the wear bar inside a cell are ONE
     object drawn at three sizes; they were three copies of one rgba that nothing
     kept in agreement. */

  --red-track: rgba(var(--op-red-idle-rgb), 0.22);

  /* THE SHADOWS, NAMED FOR THE REASON HudRoot.vue NAMES ITS ONE: more elements,
     across more files, want each of these than can be held in agreement by hand.
     A custom property set here INHERITS through the whole subtree regardless of
     scoping, which is the only way a rule written in this file can reach a cell
     drawn by `InventorySlot.vue` -- a scoped selector stops at the component
     boundary and a custom property does not. That is how the grid takes the
     surface's voice without a single `:deep()`.

       --ink        the two-pass ink every glyph on this surface sits in. There
                    is no backing and no enclosure, so a letter is on the street:
                    the tight dark pass gives it an edge, the wide soft pass
                    lifts it off a blown-out plaza. It INHERITS, so a panel
                    declares it once and the heading, the readouts and the rows
                    all take it.
       --ink-tight  the first pass on its own, for the marks that carry no text
                    and therefore take no text-shadow -- the three 2px rules.
       --dark       the separation shadow under a closed frame. Rectangular where
                    the frame is chamfered, which at this blur reads as the
                    corner darkening rather than as a second shape.
       --bloom      what a LIT control does instead of filling. It REPLACES
                    `--dark`; the two are never stacked, because a thing that is
                    both separated from the street and glowing off it is two
                    statements about one object. */
  --ink-tight: 0 1px 2px rgba(0, 0, 0, 0.95);
  --ink: var(--ink-tight), 0 0 9px rgba(0, 0, 0, 0.8);
  --dark: 0 1px 7px rgba(0, 0, 0, 0.55);
  --bloom: 0 0 18px -4px var(--op-red-glow);

  /* The control frames. 24x24, 8px corner tiles, the chamfer living entirely
     inside the top-right tile so stretching an edge can never skew it. Copied
     from MenuView.vue verbatim. A tab, a footer button, a menu row and the
     ground plate are the same control the menu's row is. */

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

/* The cursor says a drag is in flight for the whole surface and not just the cell
   it started in, which is `body.dragging *` in the old resource. `:deep` because
   the cells are a child component's elements and a scoped rule stops at the
   component boundary; it reaches only this module's own subtree. */
.room.dragging,
.room.dragging :deep(*) {
  cursor: grabbing;
}

/* =============================================================================
   THE SCREEN AND THE PAIR -- `opx77_inventory`'s `.screen` and `.frame`.
   ========================================================================== */
.screen {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  /* NO SCRIM, STILL. The old resource washed this in `--op77-scrim`; it was the
     largest fill the surface had. The two grounds added since are a cell and a
     drop bay -- fills the size of a CONTROL, which is the whole distinction: a
     plate under an item picture buys that picture a backdrop, a wash over the
     viewport buys nothing and takes the game away. */
}

/* THE TILT, RE-REASONED FOR A CENTRED LAYOUT.

   It was `+7deg` on a left-anchored bay and `-7deg` on a right-anchored one, each
   about the screen edge it was pinned to. Centred, that reasoning does not
   survive: the pair is anchored to no edge, and rule 5 of the contract derives
   both the sign and the origin from the edge a surface IS anchored to, so it
   supplies no value for something in the middle. Rotating a centred plane about
   its own centre is worse than nothing -- half of it comes toward the player and
   half goes away, which is paper twisting on a spindle, not a surface receding.

   But each PANEL still has an outer edge, so each panel keeps the rule about its
   own: the left one turns about its left edge, the right one about its right. Both
   inner edges therefore recede toward the middle and the pair reads as a shallow
   V opening toward the player -- which is what a visor actually is, two facets
   angled in around the wearer's centre line.

   The perspective lives HERE and not on a panel, and that is the whole reason the
   V reads: one vanishing point, at the centre of the pair, shared. A perspective
   per panel would give each its own and the two would simply lean.

   `scale()` from the fit rides on the same element. The panels' `rotateY` is
   flattened into it, which is correct -- one axis, no 3D box in the room. */
.frame {
  display: flex;
  align-items: flex-start;
  gap: var(--op-space-7);
  perspective: var(--op-persp);
  transform-origin: center center;
}

/* =============================================================================
   A PANEL -- a column of instruments and NO box around them.
   ========================================================================== */
.panel {
  position: relative;
  display: flex;
  flex-direction: column;
  flex: none;
  min-width: 0;
  transform-origin: var(--origin);
  transform: rotateY(var(--tilt));
  /* `layout style` and deliberately NOT `paint`. Paint containment clips to the
     padding box, and the lit tab and the chosen footer button bloom 18px past
     theirs -- with no enclosure they sit on the panel's own edge, so the bloom is
     exactly what would be cut off. The two cheap containments are kept. */
  contain: layout style;
  /* THE BLACK SHADOW, once per panel. There is no backing and now not even a
     frame, so every glyph sits directly on live gameplay. `text-shadow` inherits,
     so this one declaration carries the heading, the eyebrow, the readouts and
     the rows; the cell re-declares it for the grid, and the three floating plates
     below each carry their own because none of them is inside a panel. */
  text-shadow: var(--ink);
}

/* `--from` is the entrance offset, and it is the old resource's: each panel comes
   in from its own side toward the centre. */
.lead {
  --tilt: var(--op-tilt);
  --origin: left center;
  --from: -14px;
}

/* STRETCHED TO THE BAG'S HEIGHT, which is `.panel-right { align-self: stretch }`
   in the old resource and is what lets the ground plate fill the right-hand place
   instead of sitting as a small box at the top of it. `.frame` is a flex ROW, so
   the cross axis here is the vertical one -- this has to be on the panel and not
   on the plate inside it, where the cross axis is horizontal instead. */
.trail {
  --tilt: calc(var(--op-tilt) * -1);
  --origin: right center;
  --from: 14px;
  align-self: stretch;
}

/* =============================================================================
   THE HEAD -- type and one rule.

   The rule STAYS. It is not an enclosure: it is the only thing relating a title
   to the grid under it once the box is gone, and both the menu (`.sep::after`)
   and the old resource (`.slot .label`) draw exactly this.
   ========================================================================== */
.head {
  display: flex;
  align-items: flex-end;
  gap: var(--op-space-3);
  min-width: 0;
  min-height: 46px;
  padding-bottom: var(--op-space-2);
  border-bottom: 1px solid var(--op-red-idle);
}

.head-text {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  margin-right: auto;
  min-width: 0;
}

/* The `//` device, drawn locally. `.op77-eyebrow` in tokens.css colours its own
   `::before` with `--op77-accent`, which is yellow under `.op-theme-city`; the
   class is otherwise exactly this, and that is the only reason not to use it. */
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
  font: 700 var(--op-fs-head) / 1 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  text-transform: uppercase;
  color: var(--op-red-text);
}

.head h2 {
  margin: 0;
  font: 700 var(--op-fs-title) / 1.15 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  text-transform: uppercase;
  color: var(--op-red-text);
}

/* The open key. A frame and a letter, in the surface's own red. */
.cap {
  flex: none;
  padding: 3px 6px 4px;
  font: 700 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: var(--op-red-idle);
  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: var(--op-red-idle);
}

/* =============================================================================
   THE TABS -- a control, so each one is a closed chamfered frame.
   ========================================================================== */
.tabs {
  display: flex;
  flex-wrap: wrap;
  gap: var(--op-space-2);
  padding: var(--op-space-3) 0 var(--op-space-2);
}

.tab {
  flex: none;
  margin: 0;
  padding: var(--op-space-2) var(--op-space-3);
  font: 700 var(--op-fs-micro) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  text-transform: uppercase;
  color: var(--op-red-text);
  cursor: pointer;
  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: var(--op-red-idle);
  /* THE GROUND FOLLOWS THE CUT because augmented-ui clips the element: a plain
     `background` is the chamfered shape, where on an unclipped box it would
     repaint the very corner the chamfer removed. Each state changes ground by
     changing one property. */
  background: var(--op-plate);
  transition: color var(--op-dur-fast) linear;
}

.tab:hover:not(.on) {
  color: var(--op-red-deep);
  --aug-border-bg: var(--op-red-deep);
  --aug-border-all: 1.5px;
}

/* The active tab is the same outline as every other one. It goes bright and it
   blooms, and that is the whole of its state -- no fill, and the bloom REPLACES
   the dark shadow rather than stacking a second one on it. */
.tab.on {
  color: var(--op-red);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2.4px;
  filter: drop-shadow(0 0 7px var(--op-red-glow));
}

/* =============================================================================
   THE LOAD RULE -- a rule and not a gauge, and now a DIVIDED rule. Still no
   frame around it: a closed chamfered outline on this surface means "you can
   press this", and there are exactly four kinds of thing that can be pressed.
   Dividing a bar says how full it is; framing one would say it was a control.
   ========================================================================== */
.meter {
  display: flex;
  align-items: center;
  gap: var(--op-space-3);
  min-width: 0;
  padding: 0 0 var(--op-space-3);
}

/* In the detail plate the caption sits above its rule rather than beside it. */
.meter.stack {
  display: grid;
  gap: var(--op-space-2);
  padding: var(--op-space-2) 0 0;
}

/* A bar is the one mark on this surface that carries no text-shadow, because it
   carries no text. Over a blown-out plaza it would be the first thing to go, so
   it gets the tight ink pass as a box-shadow instead.

   IT IS SEGMENTED, WHICH IS THE ONE THING IT WAS MISSING. The token file makes
   the argument and the HUD's vitals column already acts on it: over gameplay a
   continuous fill has no edge to read against a moving backdrop, and a count of
   lit divisions can be read at a glance without being looked at. A bag that is
   seven tenths full now says seven rather than "most of the way along".

   THE DIVISIONS ARE A MASK AND NOT AN OVERLAY, and that is the whole reason this
   is allowed on a surface with no fills. An overlay would have to PAINT the
   notches in something, and the only honest something over live gameplay is
   black -- which is a fill, forty of them across the surface, and it would read
   as a dark bar with light ticks rather than as a bar with pieces missing. A
   mask removes paint instead of adding it, so the street shows through each
   notch; and because a mask applies to the element AND its children, one
   declaration cuts the track and the fill on the same grid, which is what makes
   the lit part end on a division instead of halfway across one.

   Both spellings, because the Chromium behind a CEF surface is not the one on
   this desk. A mask that does not resolve leaves an ungraduated bar, which is
   exactly what was here before and is the right thing to fall back to. */
.rule {
  --divisions: 10;

  flex: 1;
  min-width: 40px;
  /* A token, and it is a step up from the 2px this was: at 2px a 1px notch reads
     as a dotted line rather than as a division. The condition bar in the detail
     plate takes it too -- they are one instrument at two sizes. */
  height: var(--op-space-1);
  background: var(--red-track);
  box-shadow: var(--ink-tight);
  -webkit-mask-image: repeating-linear-gradient(
    to right,
    #000 0 calc(100% / var(--divisions) - 1px),
    transparent calc(100% / var(--divisions) - 1px) calc(100% / var(--divisions))
  );
  mask-image: repeating-linear-gradient(
    to right,
    #000 0 calc(100% / var(--divisions) - 1px),
    transparent calc(100% / var(--divisions) - 1px) calc(100% / var(--divisions))
  );
}

.rule i {
  display: block;
  height: 100%;
  background: var(--op-red-idle);
  transition: width var(--op-dur) linear;
}

.rule.high i {
  background: var(--op-red-hi);
}

/* THE ALARM, and it is red. The hot rung is red pushed toward white without
   leaving the hue: intensity climbs, the voice does not change. */
.rule.full i {
  background: var(--op-alarm);
}

.cap-mono {
  flex: none;
  font: 700 var(--op-fs-micro) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  text-transform: uppercase;
  color: var(--op-red-deep);
}

.figure {
  flex: none;
  font: 400 var(--op-fs-meta) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: var(--op-text-dim);
  font-variant-numeric: tabular-nums;
}

.figure.quiet {
  color: var(--op-red-idle);
}

/* =============================================================================
   THE GROUND -- the right-hand place when nothing is open beside the bag. A
   control, so it keeps a closed frame; stretched to the bag's height, as the old
   resource's `.panel-right { align-self: stretch }` did, so the pair stays square.

   AND THE ONE FILLED SURFACE ON THIS FILE, on the owner's instruction: "give the
   slots a background, and the drop one too". "The drop one" is this. It is the
   other half of what `InventorySlot.vue`'s header sets out, and the reasoning
   there is the reasoning here -- so the two do not have to be kept in agreement
   by anyone's memory, this plate takes the SAME two grounds a cell takes, at the
   same alphas:

     plate  #1c0809 @ 0.55   armed, waiting -- a bay, and a bay has a floor
     slab   #4a1519 @ 0.90   the drag is OVER it -- the identical lit slab the
                             target cell stands on, so "it lands here" is one
                             mark on this surface and not two

   BOTH ARE RED, on the owner's second word on this -- "for the inventory
   backgrounds, make them red please". #1c0809 is `--red-idle`'s rgb at 12% and
   #4a1519 is the same rgb at 32%: the surface's own red taken down until it is a
   black, which is the only way a fill can be red here and still do the job a
   fill was asked for. The alphas did not move with the hue.

   0.55 and not the cell's 0.78 because this plate is twenty times the area of a
   cell and carries two lines of display type rather than a picture: it needs to
   separate a word from the street, not hold a 50px image against a white plaza,
   and at this size 0.78 stops being a ground and becomes the panel the pass
   removed. The same argument is why the hue had to go DOWN and not up when it
   went red: at this area a red anyone can name is a red panel, and there is only
   one of those on the whole surface to notice it. The resting state multiplies
   it by the 0.45 below in any case, so with nothing in flight the floor is a
   quarter-opacity shade and the surface is still open.

   NOTHING ELSE IN THIS FILE IS FILLED and nothing else should be. The frames
   below are LOCAL COPIES of `--frame-idle` / `--frame-on` rather than an edit to
   them, precisely so this stays true: those two are shared with the tabs, the
   footer buttons and the per-slot menu rows, and putting a `fill` in them would
   have filled nine controls the owner did not ask about.
   ========================================================================== */
.ground {
  /* 24x24 and 8px tiles, as `--frame-idle` / `--frame-on`, with the ground in the
     path's own `fill` -- the same red as the stroke beside it, two depths down;
     `border-image-slice: 8 fill` paints the middle tile. */

  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: var(--op-space-3);
  min-height: 0;
  padding: var(--op-space-5);
  color: var(--op-red-idle);
  --aug-tr: var(--op-cut-md);
  --aug-border-bg: var(--op-red-idle);
  background: var(--op-plate-quiet);
  /* No outset black: it followed the border box and squared the chamfer. The
     separation is the sprite's own under-stroke now, as everywhere else. */
  /* Faint until something is actually being dragged, straight from the old
     resource: a drop zone nobody is dropping into should not compete with a bag.
     It now dims the floor along with the frame and the word, which is the whole
     reason the plate can afford to be a plate when the drag starts. */
  opacity: 0.45;
  transition:
    color var(--op-dur-fast) linear,
    opacity var(--op-dur-fast) linear;
}

.room.dragging .ground.armed {
  opacity: 1;
}

/* The slab, the bloom and the lit frame arrive together: this is the same event a
   cell's `.over` is, drawn at panel size. */
.ground.over {
  color: var(--op-red);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2.4px;
  background: var(--op-plate-lit);
  filter: drop-shadow(0 0 7px var(--op-red-glow));
  opacity: 1;
}

.ground-word {
  font: 700 var(--op-fs-lead) / 1 var(--op-font-display);
  letter-spacing: 0.14em;
  text-transform: uppercase;
  text-align: center;
}

.ground-hint {
  max-width: 24ch;
  font: 400 var(--op-fs-meta) / 1.4 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  text-align: center;
  opacity: 0.8;
}

/* =============================================================================
   THE TOLD HALF OF THE SLOT CARD -- the top of the one box a right-click opens.

   It was a separate plate the other side of the pointer, with its own ground and
   its own leading rule, opening at the same instant as the menu. Two boxes for
   one gesture, and the eye had to pick which of them it had asked for. It is the
   HEAD OF THE MENU now: the ground and the leading rule belong to the card as a
   whole (see `.menu`), and what is left here is the type -- one step down from
   the plate's, because it is read at slot size next to rows that are already
   there, and the card has to stay the size of the thing it came out of.
   ========================================================================== */
.told {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-2);
  min-width: 0;
  padding-bottom: var(--op-space-2);
  /* The divider between what the thing IS and what can be DONE with it. The same
     hairline the footer uses, so the card reads as one panel with two halves
     rather than as the two boxes it replaces. */
  border-bottom: 1px solid var(--op-red-idle);
}

.told-top {
  display: flex;
  align-items: baseline;
  gap: var(--op-space-2);
  min-width: 0;
}

/* LEAD AND NOT TITLE. 18px display caps was the plate's own heading size, and in
   a 200px card over a 50px cell it wrapped to three lines before the first row. */
.told-name {
  flex: 1 1 auto;
  min-width: 0;
  font: 700 var(--op-fs-lead) / 1.15 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  text-transform: uppercase;
  color: var(--op-red);
  overflow-wrap: anywhere;
}

/* LEGIBILITY, not meaning: it is a number the player has to read off, so white. */
.told-times {
  flex: none;
  font: 700 var(--op-fs-meta) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: var(--op-text);
  font-variant-numeric: tabular-nums;
}

/* Four lines and then an ellipsis. A description is flavour under an action list
   and must never push the rows it belongs to off the bottom of the screen. */
.told .prose {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 4;
  overflow: hidden;
  font: 400 var(--op-fs-meta) / 1.35 var(--op-font-body);
}

.fact {
  display: flex;
  align-items: baseline;
  gap: var(--op-space-3);
  min-width: 0;
  padding-bottom: var(--op-space-1);
  border-bottom: 1px solid var(--red-track);
}

.fact .value {
  margin-left: auto;
  color: var(--op-text);
}

.prose {
  margin: 0;
  font: 400 var(--op-fs-body) / 1.35 var(--op-font-body);
  color: var(--op-text-dim);
}

/* =============================================================================
   THE STATUS LINE -- under the pair, centred, and the alarm rung.
   ========================================================================== */
.status {
  position: absolute;
  left: 0;
  right: 0;
  bottom: var(--op-inset-y);
  margin: 0;
  font: 600 var(--op-fs-meta) / 1.4 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  text-align: center;
  text-transform: uppercase;
  color: var(--op-alarm);
  text-shadow: var(--ink);
}

.hint {
  margin: var(--op-space-2) 0 0;
  font: 400 var(--op-fs-meta) / 1.4 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  text-align: center;
  color: var(--op-red-idle);
  font-variant-numeric: tabular-nums;
}

/* =============================================================================
   A ROW -- a closed 1px frame with a chamfered top-right corner, and text.

   `border-image-width` is 8px while `border-width` is 1px: the image draws its
   8px corner tiles while layout only reserves one, so the chamfer is full size
   and the row still sits on a 1px box.
   ========================================================================== */
.row {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  gap: var(--op-space-3);
  min-width: 0;
  margin: 0;
  padding: var(--op-space-2) var(--op-space-3) calc(var(--op-space-2) + 1px);
  color: var(--op-red-text);
  white-space: nowrap;
  cursor: pointer;
  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: var(--op-red-idle);
  /* THE GROUND FOLLOWS THE CUT because augmented-ui clips the element: a plain
     `background` is the chamfered shape, where on an unclipped box it would
     repaint the very corner the chamfer removed. Each state changes ground by
     changing one property. */
  background: var(--op-plate);
  transition: color var(--op-dur-fast) linear;
}

.grow {
  flex: 1;
}

.row-label {
  flex: 0 1 auto;
}

.row-value {
  flex: none;
  margin-left: auto;
  opacity: 0.88;
}

.row:hover:not(.off):not(.on) {
  color: var(--op-red-deep);
  --aug-border-bg: var(--op-red-deep);
  --aug-border-all: 1.5px;
}

/* Lit and blooming, and no fill. The bloom replaces the dark shadow. */
.row.on {
  color: var(--op-red);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2.4px;
  filter: drop-shadow(0 0 7px var(--op-red-glow));
}

.row.off {
  color: var(--op-text-faint);
  cursor: default;
  --aug-border-bg: var(--op-off-line);
}

/* A captioned separator: a mono eyebrow and a rule, no frame. */
.sep {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  min-width: 0;
  padding: var(--op-space-3) 0 var(--op-space-1) var(--op-space-1);
  color: var(--op-red-deep);
}

.sep::after {
  content: "";
  flex: 1;
  height: 1px;
  background: var(--op-red-idle);
}

/* =============================================================================
   THE FOOT
   ========================================================================== */
.foot {
  display: flex;
  gap: var(--op-space-2);
  min-width: 0;
  padding-top: var(--op-space-3);
  margin-top: var(--op-space-3);
  border-top: 1px solid var(--op-red-idle);
}

/* =============================================================================
   THE SLOT CARD AND THE SPLIT STEP -- floating, outside the pair, so neither
   takes the fit or the tilt. Neither is a frame -- the rows inside are the frames
   -- but BOTH have a ground, because each carries read-off text as well as
   controls, and text with no ground of its own over live gameplay (or over a grid
   of item pictures) is text that disappears.
   ========================================================================== */
.menu-layer {
  position: absolute;
  inset: 0;
}

.menu,
.dialog {
  position: absolute;
  display: flex;
  flex-direction: column;
  text-shadow: var(--ink);
}

.menu {
  /* 200 AND NOT 220, and the rows below shrink with it. This is a context menu
     hanging off a 50px cell: it was laid out in the footer buttons' own type --
     16px display caps, 8/12 padding -- which is right for three buttons across
     the bottom of a panel and enormous for a list that pops out of a slot. It
     was 172 while it was only rows; carrying the told half as well it takes the
     28px back, and not a pixel more -- the owner asked for the SMALL scale the
     bag is drawn at. It keeps the `CARD_WIDTH` constant in the script in step;
     both are here. */
  width: 200px;
  max-height: 72vh;
  gap: var(--op-space-2);
  padding: var(--op-space-3);
  /* THE GROUND AND THE LEADING RULE, off the plate this absorbed. The two grounds
     the owner asked for are the cell and the drop bay, and this is neither -- but
     it is the one box on the surface that opens over the street rather than over
     a panel, and the plate is what the detail text was already reading against.
     No chamfer on this one, so a plain background is the right shape. */
  background: var(--op-plate);
  border-left: var(--op-rule) solid var(--op-red);
  /* Placed by `placeCard`, which offsets and flips in viewport pixels -- so no
     transform here, or the flip would be measured from the wrong corner. */
  animation: card-in var(--op-dur-fast) steps(2, end) backwards;
}

.dialog {
  left: 50%;
  top: 50%;
  width: 300px;
  transform: translate(-50%, -50%);
  /* THE CARD'S GROUND, for the card's reason. It opens dead centre, which is over the
     inner columns of both grids, and with no ground of its own its title, its 26px
     count and its range were drawn straight across item pictures. Same plate, same
     leading rule and same padding as the slot card, so the two boxes this screen pops
     are one family. */
  padding: var(--op-space-3);
  background: var(--op-plate);
  border-left: var(--op-rule) solid var(--op-red);
  animation: card-in var(--op-dur-fast) steps(2, end) backwards;
}

/* A CARD ROW IS NOT A FOOTER BUTTON. Same frame, same ground, same
   family -- one step down in type and padding, because it is read at slot size
   and there may be a dozen of them. The footer keeps the full size: three
   buttons across the bottom of a panel are the ones you aim at. */
.menu .row,
.dialog .row {
  justify-content: flex-start;
  gap: var(--op-space-2);
  padding: var(--op-space-1) var(--op-space-2) calc(var(--op-space-1) + 1px);
  font: 700 var(--op-fs-meta) / 1.2 var(--op-font-display);
  letter-spacing: 0.06em;
}

.list {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  min-width: 0;
  max-height: 44vh;
  overflow: hidden auto;
  scrollbar-width: none;
}

.list::-webkit-scrollbar {
  width: 0;
}

.stepper {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  padding-top: var(--op-space-3);
}

.stepper .count {
  flex: 1;
  text-align: center;
  font: 700 var(--op-fs-head) / 1 var(--op-font-mono);
  color: var(--op-text);
  font-variant-numeric: tabular-nums;
}

/* =============================================================================
   THE BOOT-IN -- a stutter, not a fade, on `opacity` and `transform` only.

   Each panel comes in from its own side toward the centre, which is the old
   resource's `--from: -14px / 14px`. The tilt is written into every keyframe
   through `var(--tilt)` rather than being animated: a keyframe that set only
   `translate3d` would drop the rotation for the length of the animation, and the
   panel would snap into its plane at the end.
   ========================================================================== */
@keyframes panel-in {
  0% {
    opacity: 0;
    transform: translate3d(var(--from, 0px), 0, 0) rotateY(var(--tilt));
  }

  55% {
    opacity: 1;
    transform: translate3d(calc(var(--from, 0px) * -0.15), 0, 0) rotateY(var(--tilt));
  }

  100% {
    opacity: 1;
    transform: translate3d(0, 0, 0) rotateY(var(--tilt));
  }
}

.room.open .panel {
  animation: panel-in var(--op-enter-ms) var(--op-stutter) backwards;
}

.room.open .lead {
  animation-delay: 40ms;
}

.room.open .trail {
  animation-delay: 68ms;
}

/* The card does not slide -- it is already at the pointer, and a box that travels
   to where the cursor already is reads as lag. Two steps of opacity. */
@keyframes card-in {
  from {
    opacity: 0;
  }

  to {
    opacity: 1;
  }
}

/* =============================================================================
   THE MINIMAL STYLE
   =============================================================================
   The cyberpunk bag is two tilted columns of outlined cells on dark plates,
   held together by red rules. Here each side is a printed white sheet with a
   soft shadow under it: its title in black, light then bold, a hairline under
   it, its grid of hairline squares, and a row of buttons cut off by one more
   hairline. Everything is black on white; the one colour is the pastel
   rainbow, on the thing that is active -- the chosen tab, the cell held or
   aimed at, the drop square while it is aimed at.

   The two-column arrangement, the fit-to-screen scale and every interaction
   are untouched. */
:root[data-op-style="minimal"] .room {
  --ink: none;
  --ink-tight: none;
  --red-track: var(--op-line);
  --bloom: none;
}

:root[data-op-style="minimal"] .frame {
  gap: var(--op-space-4);
  perspective: none;
}

:root[data-op-style="minimal"] .panel {
  padding: var(--op-space-5);
  color: var(--op-text);
  background: var(--op-sheet);
  box-shadow: var(--op-sheet-shadow);
  text-shadow: none;
}

/* A fade and a rise instead of a plate swinging into its slot. */
:root[data-op-style="minimal"] .room.open .panel {
  animation-name: op-min-in;
}

/* --- the head ----------------------------------------------------------------- */
:root[data-op-style="minimal"] .head {
  min-height: 0;
  padding-bottom: var(--op-space-4);
  border-bottom: 1px solid var(--op-line);
}

:root[data-op-style="minimal"] .eyebrow {
  font: 300 var(--op-fs-label) / 1 var(--op-font-body);
  color: var(--op-text-dim);
}

/* The `//` is a terminal's comment marker, and this is not a terminal. */
:root[data-op-style="minimal"] .eyebrow::before {
  content: none;
}

:root[data-op-style="minimal"] .head h1 {
  font: 700 22px / 1.1 var(--op-font-display);
  letter-spacing: -0.035em !important;
  color: var(--op-text);
}

:root[data-op-style="minimal"] .head h2 {
  font: 700 var(--op-fs-title) / 1.2 var(--op-font-display);
  color: var(--op-text);
}

:root[data-op-style="minimal"] .cap {
  --aug-border-bg: var(--op-edge-hover);
  padding: 4px 8px;
  font: 500 var(--op-fs-label) / 1 var(--op-font-body);
  color: var(--op-text);
  background: var(--op-sheet-sunk);
  text-shadow: none;
}

/* --- the tabs: a strip of cells cut by hairlines ------------------------------
   The strip is one hairline box; the tabs inside it are separated by a rule
   on their left. The chosen one keeps its white and takes a 2px rainbow line
   along its foot, the header's line on the house site. */
:root[data-op-style="minimal"] .tabs {
  gap: 0;
  align-self: flex-start;
  margin: var(--op-space-4) 0 var(--op-space-3);
  background: none;
  box-shadow: inset 0 0 0 1px var(--op-line);
}

:root[data-op-style="minimal"] .tab {
  --aug-border-bg: transparent;
  position: relative;
  padding: 8px 14px;
  font: 300 var(--op-fs-meta) / 1 var(--op-font-body);
  color: var(--op-text-dim);
  background: none;
  box-shadow: none;
  text-shadow: none;
  transition: background-color var(--op-dur-fast) var(--op-ease), color var(--op-dur-fast) var(--op-ease);
}

:root[data-op-style="minimal"] .tab + .tab {
  box-shadow: inset 1px 0 0 var(--op-line);
}

:root[data-op-style="minimal"] .tab:hover:not(.on) {
  --aug-border-bg: transparent;
  color: var(--op-text);
  background: var(--op-sheet-hover);
}

:root[data-op-style="minimal"] .tab.on {
  --aug-border-bg: transparent;
  font-weight: 600;
  color: var(--op-text);
  background:
    var(--op-rainbow-band) left bottom / 200% 2px no-repeat,
    var(--op-sheet);
  animation: op-rainbow-slide 4s linear infinite;
  filter: none;
}

/* --- the load: a hairline track and a black reading --------------------------- */
:root[data-op-style="minimal"] .meter {
  padding-bottom: var(--op-space-4);
}

:root[data-op-style="minimal"] .rule {
  height: 2px;
  overflow: hidden;
  background: var(--red-track);
  box-shadow: none;
  -webkit-mask-image: none;
  mask-image: none;
}

:root[data-op-style="minimal"] .rule i {
  background: var(--op-text);
}

:root[data-op-style="minimal"] .rule.high i {
  background: var(--op-text);
}

/* Full: the alarm is black too, and heavier -- the track thickens. */
:root[data-op-style="minimal"] .rule.full {
  height: 3px;
}

:root[data-op-style="minimal"] .rule.full i {
  background: var(--op-alarm);
}

:root[data-op-style="minimal"] .cap-mono {
  font: 300 var(--op-fs-label) / 1 var(--op-font-body);
  color: var(--op-text-dim);
}

:root[data-op-style="minimal"] .figure {
  font: 600 var(--op-fs-meta) / 1 var(--op-font-body);
  color: var(--op-text);
}

:root[data-op-style="minimal"] .figure.quiet {
  font-weight: 300;
  color: var(--op-text-dim);
}

/* --- the buttons: ghost squares, one solid black ------------------------------
   The hairline is an inset shadow on every button rather than the augmented
   ring, because the card's and the dialog's buttons are not augmented and the
   two must be the same line. */
:root[data-op-style="minimal"] .foot {
  padding-top: var(--op-space-4);
  margin-top: var(--op-space-4);
  border-top: 1px solid var(--op-line);
}

:root[data-op-style="minimal"] .row {
  --aug-border-bg: transparent;
  border: 0;
  padding: 10px var(--op-space-4);
  font: 400 var(--op-fs-meta) / 1.2 var(--op-font-body);
  color: var(--op-text);
  background: var(--op-sheet);
  box-shadow: inset 0 0 0 1px var(--op-edge-hover);
  text-shadow: none;
  transition: background-color var(--op-dur-fast) var(--op-ease), box-shadow var(--op-dur-fast) var(--op-ease);
}

:root[data-op-style="minimal"] .row:hover:not(.off):not(.on) {
  --aug-border-bg: transparent;
  color: var(--op-text);
  background: var(--op-sheet-hover);
  box-shadow: inset 0 0 0 1px var(--op-text-faint);
}

/* The one confirming button is solid black: the answer the dialog is
   waiting for, said by contrast alone. */
:root[data-op-style="minimal"] .row.on {
  --aug-border-bg: transparent;
  font-weight: 600;
  color: var(--op-sheet);
  background: var(--op-text);
  box-shadow: none;
  text-shadow: none;
  filter: none;
}

:root[data-op-style="minimal"] .row.on:hover {
  background: #262626;
}

:root[data-op-style="minimal"] .row.off {
  --aug-border-bg: transparent;
  color: var(--op-text-faint);
  background: var(--op-sheet-sunk);
  box-shadow: inset 0 0 0 1px var(--op-line);
}

/* --- the ground: a dashed square to drop into --------------------------------- */
:root[data-op-style="minimal"] .ground {
  --aug-border-bg: transparent;
  color: var(--op-text-dim);
  background: var(--op-sheet-sunk);
  border: 1px dashed var(--op-edge-hover);
  opacity: 0.7;
}

:root[data-op-style="minimal"] .ground.over {
  --aug-border-bg: transparent;
  color: var(--op-text);
  background-color: var(--op-sheet);
  background-image: var(--op-rainbow-band);
  background-size: 200% 200%;
  border: 1px solid var(--op-edge-hover);
  animation: op-rainbow-slide 6s linear infinite;
  opacity: 1;
  filter: none;
}

:root[data-op-style="minimal"] .ground-word {
  font: 600 var(--op-fs-lead) / 1.2 var(--op-font-display);
}

:root[data-op-style="minimal"] .ground-hint {
  font: 300 var(--op-fs-meta) / 1.4 var(--op-font-body);
}

/* --- the card and the count dialog: small white sheets that pop ---------------
   Each is a sheet of its own, with the house pop shadow -- it floats over the
   bag, so it is the one surface whose shadow is heavier. Inside, rows are cut
   by hairlines rather than spaced apart. */
:root[data-op-style="minimal"] .menu,
:root[data-op-style="minimal"] .dialog {
  border-left: 0;
  padding: var(--op-space-4);
  color: var(--op-text);
  background: var(--op-sheet);
  box-shadow: inset 0 0 0 1px var(--op-line), var(--op-pop-shadow);
  text-shadow: none;
  animation-name: op-min-in;
  animation-timing-function: var(--op-ease);
}

:root[data-op-style="minimal"] .menu {
  width: 220px;
}

:root[data-op-style="minimal"] .list {
  gap: 0;
}

/* A row of the card is a line in a list: white, a hairline under it, the
   pointed one greys a step. */
:root[data-op-style="minimal"] .menu .row {
  padding: 9px 4px;
  font: 400 var(--op-fs-meta) / 1.2 var(--op-font-body);
  color: var(--op-text);
  background: none;
  box-shadow: inset 0 -1px 0 var(--op-line);
}

:root[data-op-style="minimal"] .menu .row:hover:not(.off) {
  color: var(--op-text);
  background: var(--op-sheet-hover);
  box-shadow: inset 0 -1px 0 var(--op-line);
}

:root[data-op-style="minimal"] .row-value {
  font-weight: 300;
  color: var(--op-text-dim);
}

:root[data-op-style="minimal"] .dialog .row {
  justify-content: center;
}

:root[data-op-style="minimal"] .told {
  gap: var(--op-space-2);
  padding-bottom: var(--op-space-3);
  border-bottom: 1px solid var(--op-line);
}

:root[data-op-style="minimal"] .told-name {
  font: 700 var(--op-fs-lead) / 1.2 var(--op-font-display);
  color: var(--op-text);
}

:root[data-op-style="minimal"] .told-times {
  font: 300 var(--op-fs-label) / 1.2 var(--op-font-body);
  color: var(--op-text-dim);
  background: none;
}

:root[data-op-style="minimal"] .prose {
  font: 300 var(--op-fs-meta) / 1.6 var(--op-font-body);
  color: var(--op-text-dim);
}

:root[data-op-style="minimal"] .fact {
  border-bottom: 1px solid var(--op-line);
}

:root[data-op-style="minimal"] .fact .value {
  font: 600 var(--op-fs-meta) / 1.2 var(--op-font-body);
  color: var(--op-text);
}

:root[data-op-style="minimal"] .sep {
  font-weight: 300;
  color: var(--op-text-faint);
}

:root[data-op-style="minimal"] .sep::after {
  background: var(--op-line);
}

:root[data-op-style="minimal"] .stepper .row {
  width: 40px;
  height: 40px;
  padding: 0;
  font-size: var(--op-fs-title);
}

:root[data-op-style="minimal"] .stepper .count {
  font: 200 36px / 1 var(--op-font-display);
  letter-spacing: -0.04em !important;
  color: var(--op-text);
}

:root[data-op-style="minimal"] .hint {
  font: 300 var(--op-fs-meta) / 1.4 var(--op-font-body);
  color: var(--op-text-dim);
}

/* A refusal is said once, as a small black sheet: the alarm on this look is
   contrast, not hue. */
:root[data-op-style="minimal"] .status {
  left: 50%;
  right: auto;
  transform: translateX(-50%);
  padding: 10px 18px;
  font-weight: 400;
  color: var(--op-sheet);
  background: var(--op-alarm);
  box-shadow: var(--op-pop-shadow);
  text-shadow: none;
}
</style>
