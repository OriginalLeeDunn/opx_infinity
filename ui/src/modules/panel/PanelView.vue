<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { list, num, table, text, records } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { GLYPHS } from '@/modules/target/glyphs'
import { imageFromFile, monogram } from '@/modules/inventory/format'

/** A tab as this surface draws it. It was imported from `OpTabs`; the component
    is gone and the shape is three fields, so it lives where it is used. */
interface Tab {
  id: string
  label: string
  marked: boolean
  disabled: boolean
}

/**
 * THE PANEL -- and, in practice, the fitting room, because nothing else opens one.
 *
 * The mouse-driven surface, and the resource the handle pattern was taken from: Lua
 * opens with a spec and keeps the handle, every payload in either direction carries it,
 * and a message whose handle is not the open one is dropped rather than applied.
 *
 * Three things the page decides for itself, and only these three, because none of them
 * is a fact about the world:
 *  - the search filter, over items Lua has already sent;
 *  - where the dial is standing, and therefore which slice of the list is drawn;
 *  - whether the confirm dialog is on screen.
 * Everything else is Lua's answer, applied verbatim. The panel does not select an item
 * because it was clicked; it says it was clicked and waits for `selected` to come back.
 *
 * ── WHAT THIS SCREEN IS, AND WHY IT IS LAID OUT LIKE THIS ───────────────────────────
 *
 * A player dressing a character is looking at the character. Everything here is
 * arranged around that one fact, which the previous layout did not concede: it filled
 * the screen with a scrim, put a 600px drawer down the middle-left with a title block
 * on top of it, and paged a two-column wall of names. The body was behind all of it.
 *
 * So: NO SCRIM -- the room is transparent and the player watches their own character
 * through it. NO HEADER -- the tab strip is the first thing in the column and it says
 * what the screen is by naming the seven slots, which is more than 'WARDROBE' ever
 * said. `eyebrow`, `title` and `subtitle` still arrive and are simply not drawn; that
 * is `MenuView`'s precedent for the same decision, and the cost is the same -- the
 * panel no longer names itself, and a second caller would have to live with that.
 * `intro` IS drawn, because it is the one of the four that states something the screen
 * cannot show: that nothing is kept until you save.
 *
 * ── THE DIAL, WHICH IS WHERE THE SLIDER WENT ────────────────────────────────────────
 *
 * Browsing a slot's pieces is one-dimensional and ordered, every step has a visible
 * consequence on the body, and the seam already carries a preview -- `hover` shows a
 * piece without choosing it and `select` chooses it. That is a slider, exactly: drag,
 * and the body wears what is under the thumb; let go, and that is your choice.
 * `@input` previews through the same debounced hover a pointer uses, `@change` commits.
 * A keyboard does both per arrow press, which is the behaviour you want.
 *
 * It replaced the pager, not the list. The list is still under the dial as a window
 * that follows the thumb, because a slider with no names beside it tells the player
 * nothing about where they are, and clicking a row is still the precise way to land on
 * one. `columns` keeps meaning what it meant: how many of that window sit abreast.
 *
 * ── THE RAIL, WHICH IS WHAT A `sliders` CALLER GETS ─────────────────────────────────
 *
 * A caller that sends `sliders` instead of items gets a different screen: the whole
 * left side of the surface, floor to ceiling, holding the view buttons, the other
 * screens reachable from this one, the categories, a scrolling grid of the open
 * category, and one track. The items column, the search plate and the paged window are
 * not drawn, because that caller kept its lists.
 *
 * WHAT IT REPLACED, AND WHY TWICE OVER. It was a bar of tracks along the bottom of the
 * screen. The owner, on the fitting room: "je le veux sur la gauche, plus en bas au
 * centre car cela cache le joueur", and then "tu peux prendre tout le cote gauche de
 * l'ecran". And on the picker: "mettre des box avec l'image du vetement uniquement, de
 * sorte a rendre le choix plus facile -- donc il scroll pour descendre et voir plus."
 * A grid the player scrolls needs height, and the bottom of the screen is where the
 * legs are.
 *
 * SEVEN TRACKS BECAME SEVEN TABS AND ONE TRACK. A tab strip exists to show one of
 * seven things at a time, which is exactly what a category picker is; a player
 * dressing a character is on one slot at a time anyway, and the mark on a closed tab
 * says whether that slot has anything on it. And `ui/README.md` rule 2 now points the
 * other way from the bar it replaced: a row of controls took no enclosure, but a
 * column that is the screen's whole left edge is a surface, so it keeps the `.op-bay`,
 * the `.op-arete` leading edge and the left hinge the items column has always had.
 *
 * THE GRID IS A WINDOW, NOT A LIST. The largest clothing category is 677 records and
 * the whole catalogue about 1968; streaming them as `items` is the defect the slider
 * was introduced to delete, and a grid that asked for all of them again would put it
 * straight back. The page holds the slice it has been sent and asks for the next one
 * on the way down. A box carries the index it would have had on the track, so a click
 * is the same `slide` a thumb sends and nothing new decides anything. See `Tiles`.
 *
 * AND THE TRACK STAYS, for the open category only. It is not leftover: sixty boxes at
 * a time means position 412 is seven windows of scrolling, while the track and the
 * number box beside it get there in one gesture -- and it is the control for a
 * category whose boxes are monograms, which is any record the garment data has no
 * picture for.
 *
 * THE THUMB IS THE PAGE'S, THE INDEX IS THE CALLER'S. `@input` previews through a
 * debounce and `@change` commits, exactly as the dial does -- but a drag outruns the
 * answers, so the page holds its own position per slot while the player is on it and
 * lets the caller's index win again the moment they let go. That is how a refused
 * piece puts the thumb back: the caller answers with the index it still believes in.
 */

type Handle = string | number

interface Button {
  id: string
  label: string
  /** A name out of `OPX.Glyphs`, or '' for a button that is words alone. Lua validates
      it against the same set, so an unknown name here is a bug on one side or the
      other and draws nothing rather than reaching into `GLYPHS` for a missing key. */
  icon: string
  primary: boolean
  disabled: boolean
}

interface Item {
  id: string
  tab: string
  label: string
  detail: string
  disabled: boolean
  /** label + detail + id, lower-cased once so the filter is not re-lowering per keystroke. */
  search: string
}

interface Summary {
  label: string
  value: string
  action: Button | null
}

/** One named range. `count` is how many positions it has past 0, and 0 is a real
    position -- it is how a caller offers "none of them" without a second control. */
interface Slider {
  id: string
  label: string
  count: number
  index: number
  value: string
  disabled: boolean
}

/**
 * THE PICKER GRID, one category's worth of boxes.
 *
 * A caller that sends `sliders` is offering ranges it keeps the contents of; `tiles`
 * is how it lends the page the SLICE of one of those ranges the player can see. The
 * page never learns the whole list -- the fitting room's largest category is 677
 * records -- it holds what it has been sent, draws a box per entry, and asks for the
 * next window when the scroll reaches the bottom of what it holds.
 *
 * `slot` is the slider the window belongs to, so a window that arrives after the
 * player has moved on is filed against the category it names and dropped. `entries`
 * is record names in index order starting at 1: the box at offset `n` is position
 * `n + 1` on that slider's track, which is what a press reports.
 *
 * `labels` and `images` ride beside `entries`, one per box, both optional: the
 * caption (the item's own name) and the picture's file name under
 * `images/clothing/`. Lua decides both -- it knows the body family and holds the
 * generated garment data -- so the page never guesses a file name, and a box with
 * no picture never asks for one: it draws the monogram straight away.
 */
interface Tile {
  name: string
  label: string
  image: string
}

interface Tiles {
  slot: string
  entries: Tile[]
}

/** The confirm step. Parsed on arrival rather than kept as a raw payload, so the
    template never reaches into an `unknown` and a malformed dialog cannot render. */
interface Dialog {
  id: string
  title: string
  text: string
  yes: string
  no: string
}

interface PanelView {
  /** Arrives and is not drawn. See the header. */
  eyebrow: string
  title: string
  subtitle: string
  intro: string
  tabs: Tab[]
  tab: string
  /** One control per named range. Non-empty is what puts the slot bar on screen
      instead of the column; see the header. */
  sliders: Slider[]
  /** `false` hides the search plate; a string is its placeholder. */
  search: string | false
  summary: Summary | null
  actions: Button[]
  tools: Button[]
  /** Other parts of this same screen, drawn as a strip above the slot bar. Not
      `tools` (which adjust the view) and not `actions` (which finish with the
      panel): the fitting room's saved outfits, share codes and ready-made looks
      are none of those, and a button that means "go somewhere else in here"
      reads wrong in either of the other two rows. */
  groups: Button[]
  /** Per tab: the id of the item Lua considers chosen there. */
  selected: Record<string, string>
  status: { text: string; kind: string } | null
  busy: boolean
  loading: boolean
  labels: Record<string, string>
  /** Spec-only: whether Lua wants to hear about the pointer at all. */
  hover: boolean
  columns: 1 | 2
}

/* The window is sized by measured height, so a column that is short on one screen and
   tall on another shows what fits rather than a fixed count. These are only the guess
   used before the first row has been drawn: once one exists its real height and the
   grid's real gap are measured and used instead (#118). The guess was panel.js's 58px,
   while the row this file draws is 40px -- a third of every window stood empty under
   its last row. */
const ROW_HEIGHT = 40
const ROW_GAP = 4
const HOVER_MS = 110
const LEAVE_MS = 160

/* How close to the end of the grid the scroll gets before the next window is asked
   for, in pixels. A little over one row of boxes: the window is in flight while the
   player is still reading the row above the last one, so a steady scroll never stops
   at a bottom that has not filled in yet. */
const TILE_LOOKAHEAD = 160

/* How long a window request waits before the grid is free to ask again. Long
   enough that an ordinary answer lands first, short enough that a dropped one
   costs a pause rather than the rest of the category. */
const TILE_WAIT_MS = 2000

function emptyView(): PanelView {
  return {
    eyebrow: '',
    title: '',
    subtitle: '',
    intro: '',
    tabs: [],
    tab: '',
    sliders: [],
    search: false,
    summary: null,
    actions: [],
    tools: [],
    groups: [],
    selected: {},
    status: null,
    busy: false,
    loading: false,
    labels: {},
    hover: false,
    columns: 2
  }
}

const handle = ref<Handle | null>(null)
const open = ref(false)
const view = reactive<PanelView>(emptyView())
const items = ref<Item[]>([])
/** Where the dial is standing, as an index into the filtered list. */
const cursor = ref(0)
const query = ref('')
const dialog = ref<Dialog | null>(null)

/** Where the player is holding each slot's thumb, for slots they have touched. It
    is dropped for a slot as soon as the caller answers about it -- unless they are
    still dragging that one, because a drag outruns the answers and a thumb yanked
    back under a finger is worse than a label a frame behind. */
const thumb = reactive<Record<string, number>>({})

const gridEl = ref<HTMLElement | null>(null)
const gridHeight = ref(0)
/** One row plus the gap under it, as last measured off a drawn row. 0 until one is. */
const rowPitch = ref(0)

/** The window of the open category the page is holding. See `Tiles`. */
const tiles = reactive<Tiles>({ slot: '', entries: [] })

/** Record names whose picture would not load, so the box draws a monogram from then
    on for every box holding that record rather than retrying the image per box. It is
    the same bookkeeping `InventorySlot` does, kept here because this page has no
    catalogue and no parent to report a broken picture up to. */
const broken = reactive<Record<string, true>>({})

/** True between asking for the next window and it arriving. A grid the player flicks
    fires a scroll event per frame, and without this every one of them would ask for
    the same window again -- sixty names a frame across the seam for one gesture. */
const fetching = ref(false)

const tilesEl = ref<HTMLElement | null>(null)

let hovered: string | null = null
let hoverTimer: ReturnType<typeof setTimeout> | undefined
let leaveTimer: ReturnType<typeof setTimeout> | undefined
let slideTimer: ReturnType<typeof setTimeout> | undefined
let tilesTimer: ReturnType<typeof setTimeout> | undefined
/** The slot whose thumb is under the pointer, or null. */
let dragging: string | null = null
let release: (() => void) | undefined
let releaseDialog: (() => void) | undefined

function isHandle(value: unknown): value is Handle {
  return typeof value === 'string' || typeof value === 'number'
}

function mine(payload: Payload): boolean {
  return handle.value !== null && payload.handle === handle.value
}

/** The view's own label table, which a caller's spec overrides -- not `useLocale`. The
    strings are Lua's already-translated defaults, or the caller's replacements. */
function label(key: string, vars?: Record<string, number | string>): string {
  const template = text(view.labels[key])
  if (!vars) return template
  return template.replace(/\{(\w+)\}/g, (whole, name: string) => {
    const value = vars[name]
    return value === undefined ? whole : String(value)
  })
}

function readButtons(value: unknown): Button[] {
  return records(value).map((entry) => {
    const icon = text(entry.icon)
    return {
      id: text(entry.id),
      label: text(entry.label),
      // CHECKED AGAINST THE PATHS THIS FILE CAN ACTUALLY DRAW. Lua validates the
      // same name against `OPX.Glyphs`, which is generated from this very table --
      // but the two files cannot import each other, so a name that got past Lua and
      // has no path here is dropped rather than turned into an empty `<svg>` with
      // no `<path>` in it, which is a blank box the player is invited to click.
      icon: icon !== '' && Object.prototype.hasOwnProperty.call(GLYPHS, icon) ? icon : '',
      primary: entry.primary === true,
      disabled: entry.disabled === true
    }
  })
}

function readSummary(value: unknown): Summary | null {
  const source = table(value)
  if (Object.keys(source).length === 0) return null
  const action = table(source.action)
  return {
    label: text(source.label),
    value: text(source.value),
    action: Object.keys(action).length === 0 ? null : readButtons([action])[0]
  }
}

/**
 * Applies whatever the payload carries and leaves the rest alone -- panel.js walked the
 * payload's own keys for exactly this reason, and `opx:panel:update` is a patch. The
 * difference here is that the key list is written down: an unknown field is dropped
 * instead of being written into the view under a name nothing renders.
 */
function apply(payload: Payload): void {
  const given = (key: string): boolean => payload[key] !== undefined
  // Kept, and not drawn. The three of them are the header this screen no longer has;
  // holding them means a caller is not silently refused and a later surface may draw
  // them again without a contract change.
  if (given('eyebrow')) view.eyebrow = text(payload.eyebrow)
  if (given('title')) view.title = text(payload.title)
  if (given('subtitle')) view.subtitle = text(payload.subtitle)
  if (given('intro')) view.intro = text(payload.intro)
  if (given('tabs')) {
    view.tabs = records(payload.tabs).map((tab) => ({
      id: text(tab.id),
      label: text(tab.label),
      marked: tab.marked === true,
      disabled: tab.disabled === true
    }))
  }
  if (given('tab')) view.tab = text(payload.tab)
  if (given('sliders')) {
    const incoming = records(payload.sliders).map((entry) => ({
      id: text(entry.id),
      label: text(entry.label),
      count: Math.max(0, num(entry.count)),
      index: Math.max(0, num(entry.index)),
      value: text(entry.value),
      disabled: entry.disabled === true
    }))
    // The caller has spoken about these slots, so its index is the truth again --
    // for every one of them except the slot still under the player's finger.
    for (const entry of incoming) if (dragging !== entry.id) delete thumb[entry.id]
    view.sliders = incoming
  }
  if (given('search')) view.search = payload.search === false ? false : text(payload.search)
  if (given('summary')) view.summary = readSummary(payload.summary)
  if (given('actions')) view.actions = readButtons(payload.actions)
  if (given('tools')) view.tools = readButtons(payload.tools)
  if (given('groups')) view.groups = readButtons(payload.groups)
  if (given('selected')) {
    // Merged, not replaced: an update naming one tab's choice must not forget the others.
    const incoming = table(payload.selected)
    for (const key of Object.keys(incoming)) view.selected[key] = text(incoming[key])
  }
  if (given('status')) {
    const status = table(payload.status)
    view.status = Object.keys(status).length === 0
      ? null
      : { text: text(status.text), kind: text(status.kind, 'info') }
  }
  if (given('busy')) view.busy = payload.busy === true
  if (given('loading')) view.loading = payload.loading === true
  if (given('labels')) {
    const incoming = table(payload.labels)
    const next: Record<string, string> = {}
    for (const key of Object.keys(incoming)) next[key] = text(incoming[key], key)
    view.labels = next
  }
  if (given('tiles')) applyTiles(payload.tiles)
  if (given('hover')) view.hover = payload.hover === true
  if (given('columns')) view.columns = num(payload.columns) === 1 ? 1 : 2
}

/**
 * One window of the grid, replacing what is held or extending it.
 *
 * THE THREE CASES, AND THE THIRD IS THE ONE THAT MATTERS. A window for another
 * category, or one starting at 1, REPLACES -- that is a new grid. A window starting
 * exactly where the held one ends EXTENDS it. Anything else is dropped: a window that
 * skipped ahead would leave a hole in the middle of the grid that nothing would ever
 * fill, and every box after the hole would carry an index that is off by the size of
 * it -- which is a player clicking a jacket and being dressed in a different one.
 */
/** A window applied, then -- if it added boxes -- the grid topped up while it does not
    yet overflow. `askForTiles` was only ever reached from a scroll event, and a first
    window that fits without scrolling (a tall screen, a short window from the caller)
    never fires one: the "loading" line stayed up forever over a grid that would not
    grow. Only after a window that GREW, so a caller answering with nothing cannot turn
    this into a request loop. */
function applyTiles(value: unknown): void {
  if (readTiles(value)) void nextTick(topUpTiles)
}

function topUpTiles(): void {
  const el = tilesEl.value
  if (el && el.scrollTop + el.clientHeight >= el.scrollHeight - TILE_LOOKAHEAD) askForTiles()
}

function readTiles(value: unknown): boolean {
  if (tilesTimer !== undefined) clearTimeout(tilesTimer)
  tilesTimer = undefined
  fetching.value = false
  const source = table(value)
  const slot = text(source.slot)
  if (slot === '') {
    tiles.slot = ''
    tiles.entries = []
    return false
  }
  const labels = list<unknown>(source.labels)
  const images = list<unknown>(source.images)
  const entries = list<unknown>(source.entries).map((entry, at): Tile => {
    const name = text(entry)
    return { name, label: text(labels[at]) || name, image: text(images[at]) }
  })
  const from = num(source.from)
  if (slot !== tiles.slot || from === 1) {
    tiles.slot = slot
    tiles.entries = entries
    return entries.length > 0
  }
  if (from !== tiles.entries.length + 1) return false
  tiles.entries = tiles.entries.concat(entries)
  return entries.length > 0
}

/** The tab actually drawn: the one Lua named if it still exists, else the first. */
const currentTab = computed(() => {
  if (view.tabs.length === 0) return ''
  if (view.tabs.some((tab) => tab.id === view.tab)) return view.tab
  return view.tabs[0].id
})

const chosen = computed(() => text(view.selected[currentTab.value]))

const shown = computed(() => {
  const tab = currentTab.value
  const needle = query.value.trim().toLowerCase()
  return items.value.filter((item) => {
    if (tab !== '' && item.tab !== '' && item.tab !== tab) return false
    return needle === '' || item.search.indexOf(needle) !== -1
  })
})

/** The dial's real position. `cursor` is clamped here rather than on write, because the
    list shrinks under it: a batch arriving, a tab changing and a keystroke in the search
    field all move the floor without the player touching the dial. */
const at = computed(() => Math.max(0, Math.min(cursor.value, shown.value.length - 1)))

const windowSize = computed(() => {
  const pitch = rowPitch.value > 0 ? rowPitch.value : ROW_HEIGHT + ROW_GAP
  const gap = rowPitch.value > 0 ? rowGap : ROW_GAP
  const rows = Math.max(1, Math.floor((gridHeight.value + gap) / pitch))
  return rows * (view.columns === 1 ? 1 : 2)
})

/* The window follows the thumb instead of jumping a page at a time, and it stops at both
   ends rather than centring on a position the list does not have. */
const windowStart = computed(() => {
  const size = windowSize.value
  const last = Math.max(0, shown.value.length - size)
  return Math.max(0, Math.min(at.value - Math.floor(size / 2), last))
})

const visible = computed(() =>
  shown.value.slice(windowStart.value, windowStart.value + windowSize.value)
)

const count = computed(() => {
  if (shown.value.length === 0) return ''
  return label('count', {
    from: windowStart.value + 1,
    to: Math.min(shown.value.length, windowStart.value + windowSize.value),
    total: shown.value.length
  })
})

const gridStyle = computed(() => `--columns: ${view.columns}`)

/** `search` carries two things -- whether the plate is drawn and what it says -- so the
    template gets a string and the `v-if` gets the boolean. */
const searchPlaceholder = computed(() => (view.search === false ? '' : view.search))

const summaryAction = computed(() => view.summary?.action ?? null)

/** Where in the filtered list Lua's own choice sits, or the top when it is not in it. */
function indexOfChosen(): number {
  if (chosen.value === '') return 0
  const found = shown.value.findIndex((item) => item.id === chosen.value)
  return found < 0 ? 0 : found
}

/* THE DIAL FOLLOWS LUA, NOT THE OTHER WAY ROUND. A tab the player opened, and a choice
   Lua made -- including `remove`, which sets the slot to nothing -- both move the thumb
   to where the truth now is. Without this the dial would still be standing over the
   jacket the player just took off. */
watch([currentTab, chosen], () => {
  cursor.value = indexOfChosen()
})

/* A new filter is a new list, and an index into the old one means nothing in it. */
watch(query, () => {
  cursor.value = 0
})

/** The grid's own row gap, read with the row; see `rowPitch`. */
let rowGap = ROW_GAP

/**
 * THE WINDOW'S TWO MEASUREMENTS, and why neither can feed back into the other (#118).
 *
 * The grid's height is the remainder of a column of definite height: `.grid` is
 * `flex: 1 1 0` with `min-height: 0`, so its size is decided by what is ABOVE and
 * BELOW it -- the dial, the readout, the summary, the status line -- and never by the
 * rows inside it. The row's height is its own padding and one line of type, and does
 * not depend on the grid at all. So a measure changes the window, the window changes
 * which rows are drawn, and drawing them changes neither number: one pass, no loop.
 */
function measure(): void {
  const grid = gridEl.value
  gridHeight.value = grid?.clientHeight ?? 0
  const row = grid?.querySelector<HTMLElement>('.row') ?? null
  if (grid && row) {
    // `offsetHeight` and not the bounding box: the column is tilted, and a
    // perspective projection would report every row at a different height.
    const gap = parseFloat(getComputedStyle(grid).rowGap)
    rowGap = Number.isFinite(gap) ? gap : ROW_GAP
    rowPitch.value = row.offsetHeight + rowGap
  }
}

/* THE GRID IS MEASURED WHENEVER IT CHANGES SIZE, not only on open and on a window
   resize. It is the flexible box in a full-height column, so the dial, the readout,
   the summary and the status line arriving with the first items all take height from
   it -- and a window sized at open, before any of them existed, held more rows than
   now fit: the last ones were cut through by the grid's own overflow, the cursor's
   among them. Content cannot feed back into this: the grid's height is the column's
   remainder, never its rows'. */
let sizer: ResizeObserver | null = null

watch(gridEl, (element, previous) => {
  if (typeof ResizeObserver === 'undefined') return
  if (sizer === null) sizer = new ResizeObserver(() => measure())
  if (previous) sizer.unobserve(previous)
  if (element) sizer.observe(element)
}, { flush: 'post' })

/* The first rows drawn are the first chance to measure one. Only the edge from none to
   some: after that the pitch is known, and a window that slides draws rows of the same
   height. */
watch(() => visible.value.length > 0, (some) => {
  if (some) measure()
}, { flush: 'post' })

function clearHoverTimers(): void {
  if (hoverTimer !== undefined) clearTimeout(hoverTimer)
  if (leaveTimer !== undefined) clearTimeout(leaveTimer)
  if (slideTimer !== undefined) clearTimeout(slideTimer)
  if (tilesTimer !== undefined) clearTimeout(tilesTimer)
  hoverTimer = undefined
  leaveTimer = undefined
  slideTimer = undefined
  tilesTimer = undefined
}

/** Debounced both ways: a pointer crossing a grid must not raise an event per row, and
    a pointer that left for two frames on its way to the next row has not left. A dial
    dragged across four hundred pieces is the same problem with a different input, so it
    goes through the same gate. */
function pointAt(id: string): void {
  if (!view.hover || handle.value === null) return
  clearHoverTimers()
  hoverTimer = setTimeout(() => {
    hoverTimer = undefined
    if (handle.value === null || hovered === id) return
    hovered = id
    emit('opx:panel:hover', { handle: handle.value, item: id })
  }, HOVER_MS)
}

function pointAway(): void {
  if (!view.hover || handle.value === null) return
  clearHoverTimers()
  leaveTimer = setTimeout(() => {
    leaveTimer = undefined
    if (handle.value === null || hovered === null) return
    hovered = null
    emit('opx:panel:leave', { handle: handle.value })
  }, LEAVE_MS)
}

function closeDialog(): void {
  dialog.value = null
  releaseDialog?.()
  releaseDialog = undefined
}

/** The confirm answer. Both buttons take the dialog down here rather than waiting for
    Lua, because the dialog is the page's own and a handler that reopens one would
    otherwise race its own dismissal. The ANSWER is still entirely Lua's to act on. */
function answer(value: boolean): void {
  const current = dialog.value
  if (!current) return
  closeDialog()
  emit('opx:panel:answer', { handle: handle.value, id: current.id, value })
}

function blank(): void {
  clearHoverTimers()
  hovered = null
  dragging = null
  for (const key of Object.keys(thumb)) delete thumb[key]
  open.value = false
  items.value = []
  cursor.value = 0
  query.value = ''
  tiles.slot = ''
  tiles.entries = []
  fetching.value = false
  // The broken-picture set goes with the panel and not with the session: a file that
  // was missing when the last room opened may have been shipped since, and a page that
  // never forgot would draw monograms for the rest of the client's life.
  for (const key of Object.keys(broken)) delete broken[key]
  closeDialog()
  Object.assign(view, emptyView())
}

useBridge('opx:panel:open', (payload: Payload) => {
  guard('panel:open', () => {
    if (!isHandle(payload.handle)) return
    release?.()
    cancelWipe()
    blank()
    handle.value = payload.handle
    apply(payload)
    open.value = true
    release = acquireFocus({
      id: 'panel',
      // `dismiss` is `close` or `ask` in the spec, and which one it is belongs to Lua.
      onEscape: () => emit('opx:panel:dismiss', { handle: handle.value })
    })
    void nextTick(measure)
  }, undefined)
})

useBridge('opx:panel:update', (payload: Payload) => {
  guard('panel:update', () => {
    if (!mine(payload)) return
    const before = currentTab.value
    apply(payload)
    if (payload.clearItems === true) items.value = []
    // A tab Lua switched under us resets the filter, exactly as a tab the player
    // switched does: the query belonged to the list that is no longer shown. The dial
    // is moved by the watcher above, which sees the same change.
    if (currentTab.value !== before) query.value = ''
  }, undefined)
})

useBridge('opx:panel:items', (payload: Payload) => {
  guard('panel:items', () => {
    if (!mine(payload)) return
    const batch: Item[] = []
    for (const entry of records(payload.items)) {
      const id = text(entry.id)
      if (!id) continue
      const itemLabel = text(entry.label)
      const detail = text(entry.detail)
      batch.push({
        id,
        tab: text(entry.tab),
        label: itemLabel,
        detail,
        disabled: entry.disabled === true,
        search: `${itemLabel} ${detail} ${id}`.toLowerCase()
      })
    }
    // Appended: `opx:panel:items` is a batch, and a catalogue of five thousand rows
    // arrives in many. `clearItems` on an update is what empties the list.
    items.value = items.value.concat(batch)
    if (payload.done === true) {
      view.loading = false
      // The dial could not stand on Lua's choice while the piece had not arrived yet.
      cursor.value = indexOfChosen()
    }
  }, undefined)
})

useBridge('opx:panel:confirm', (payload: Payload) => {
  guard('panel:confirm', () => {
    if (!mine(payload)) return
    // `id = false` takes the dialog down without an answer -- Lua withdrawing its own
    // question, which happens when the thing being confirmed stopped being true.
    const id = text(payload.id)
    if (id === '') {
      closeDialog()
      return
    }
    dialog.value = {
      id,
      title: text(payload.title),
      text: text(payload.text),
      yes: text(payload.yes),
      no: text(payload.no)
    }
    releaseDialog?.()
    /* A second owner OVER the panel's. Releasing it hands focus back to `panel`, which
       is the whole reason bridge/focus.ts is a stack: a confirm that released to nothing
       would leave a panel on screen that no longer answers the keyboard. */
    releaseDialog = acquireFocus({ id: 'panel.confirm', onEscape: () => answer(false) })
  }, undefined)
})

/* A CLOSED PANEL KEEPS WHAT IT WAS SHOWING UNTIL THE FADE HAS RUN. `blank()` in the
   same tick as the close emptied the view under a 150ms fade: the fitting room's rail
   lost its sliders and the items column -- an empty bay -- faded out in its place, and
   any other panel collapsed to its frame. The hover timers, the dialog and the focus
   still go at once; the rest follows when nothing can see it. */
const WIPE_MS = 240
let wipe: ReturnType<typeof setTimeout> | undefined

function cancelWipe(): void {
  if (wipe !== undefined) clearTimeout(wipe)
  wipe = undefined
}

useBridge('opx:panel:close', (payload: Payload) => {
  guard('panel:close', () => {
    if (payload.handle !== undefined && !mine(payload)) return
    handle.value = null
    open.value = false
    clearHoverTimers()
    closeDialog()
    release?.()
    release = undefined
    cancelWipe()
    wipe = setTimeout(() => {
      wipe = undefined
      if (!open.value) blank()
    }, WIPE_MS)
  }, undefined)
})

onMounted(() => {
  window.addEventListener('resize', measure)
  measure()
})

onUnmounted(() => {
  sizer?.disconnect()
  sizer = null
  cancelWipe()
  window.removeEventListener('resize', measure)
  clearHoverTimers()
  releaseDialog?.()
  release?.()
})

function chooseTab(id: string): void {
  if (id === currentTab.value) return
  // The page shows the new tab at once because the tab strip is a view of items it
  // already holds; `selected` -- what the tab CONTAINS -- still comes from Lua.
  view.tab = id
  query.value = ''
  clearHoverTimers()
  hovered = null
  // THE OLD GRID GOES AT ONCE. It belongs to the category the player just left, and
  // leaving it up until the new window lands would show them a screen of the wrong
  // garments with the new category's name over it -- and a click on one of those boxes
  // would carry an index into a list that is no longer the open one.
  tiles.slot = ''
  tiles.entries = []
  fetching.value = false
  if (tilesEl.value) tilesEl.value.scrollTop = 0
  emit('opx:panel:tab', { handle: handle.value, tab: id })
}

function choose(item: Item): void {
  if (item.disabled || view.busy) return
  emit('opx:panel:select', { handle: handle.value, item: item.id })
}

/** A row clicked: the dial moves to it as well, so the two never disagree.
    Found by id rather than by the row's offset in the window: a row is memoised
    (`v-memo` in the template) and keeps the handler it was drawn with, so an
    offset captured then would be stale as soon as the window slid under it. */
function pick(item: Item): void {
  const index = shown.value.findIndex((entry) => entry.id === item.id)
  if (index >= 0) cursor.value = index
  choose(item)
}

/** The thumb moved: preview only. Committing on every intermediate value of a drag
    would put four hundred selections through the seam for one gesture. */
function scrub(raw: string): void {
  const length = shown.value.length
  if (length === 0) return
  const index = Math.max(0, Math.min(length - 1, Math.trunc(Number(raw)) || 0))
  cursor.value = index
  const item = shown.value[index]
  if (item && !item.disabled) pointAt(item.id)
}

/** The thumb let go, or an arrow key pressed: that is the choice. */
function settle(): void {
  const item = shown.value[at.value]
  if (item) choose(item)
}

/* ── the slot bar ───────────────────────────────────────────────────────────── */

/** Where one slot's thumb is drawn: the player's hold on it, or the caller's index.
    Clamped against the caller's count, because a track can shrink under a hold. */
function standing(slider: Slider): number {
  const held = thumb[slider.id]
  return held === undefined ? Math.min(slider.index, slider.count) : Math.min(held, slider.count)
}

/* ── the picker grid ────────────────────────────────────────────────────────── */

/** The slider the open category belongs to, or null when there is no such slot. */
const openSlider = computed<Slider | null>(
  () => view.sliders.find((slider) => slider.id === currentTab.value) ?? null
)

/** The boxes to draw, each carrying the track position a press reports. */
const boxes = computed(() => {
  if (tiles.slot !== currentTab.value) return []
  return tiles.entries.map((tile, offset) => ({ index: offset + 1, ...tile }))
})

/** Whether the category holds more than the page has been sent. */
const moreToLoad = computed(() => {
  const slider = openSlider.value
  if (slider === null || tiles.slot !== slider.id) return false
  return tiles.entries.length < slider.count
})

/** The garment's picture. `imageFromFile` is the one place the `images/` base lives --
    `ui/public/images` is the source and `web/images` the build's copy of it -- so this
    borrows it rather than writing a second copy of the path. The garments have a
    folder of their own under it, so a garment file can never collide with an item's.
    The file name is the one Lua sent; see `Tiles`. */
function art(name: string, file: string): string {
  return imageFromFile(name, `clothing/${file}`)
}

/** A picture that will not load, recorded once so every box holding that record draws
    the monogram from then on instead of asking for the file again. With the garment
    pictures shipped this is the rare path -- a file named in the data but missing
    from `web/images/clothing` -- and the grid still works when it is taken. */
function artBroken(name: string): void {
  broken[name] = true
}

/** Where the grid has got to. `Math.round` because a fractional `scrollTop` on a
    zoomed surface never reaches the exact bottom, and a threshold of one box's height
    asks for the next window slightly before the player runs out of grid. */
function onTilesScroll(event: Event): void {
  const el = event.target as HTMLElement
  if (el.scrollTop + el.clientHeight < el.scrollHeight - TILE_LOOKAHEAD) return
  askForTiles()
}

function askForTiles(): void {
  if (fetching.value || !moreToLoad.value || handle.value === null) return
  fetching.value = true
  // A REQUEST THE CALLER DOES NOT ANSWER MUST NOT END THE SCROLLING. Every
  // message across this seam may be dropped -- by a stale handle, by a category
  // that changed under the request, by a caller that simply decided not to --
  // and a flag that is only ever cleared by an answer would leave the grid stuck
  // at the sixtieth box for the rest of the room, with nothing on screen saying
  // why. The next scroll event after the window asks again.
  if (tilesTimer !== undefined) clearTimeout(tilesTimer)
  tilesTimer = setTimeout(() => {
    tilesTimer = undefined
    fetching.value = false
  }, TILE_WAIT_MS)
  emit('opx:panel:tiles',
    { handle: handle.value, slot: tiles.slot, from: tiles.entries.length + 1 })
}

/** A box clicked: the same choice the thumb makes when it is let go on that position,
    reported through the same message. The grid is a way to POINT at an index, not a
    second way to choose -- everything about what an index means is still Lua's. */
function pickTile(index: number): void {
  const slider = openSlider.value
  if (slider === null || slider.disabled || view.busy) return
  if (index < 0 || index > slider.count) return
  thumb[slider.id] = index
  if (slideTimer !== undefined) clearTimeout(slideTimer)
  slideTimer = undefined
  dragging = null
  if (handle.value === null) return
  emit('opx:panel:slide', { handle: handle.value, id: slider.id, index, commit: true })
}

/** One slot's thumb moved: preview only, and debounced through the same gate the
    pointer uses. Committing every intermediate value of a drag would put four
    hundred choices across the seam for one gesture. */
function scrubSlot(slider: Slider, raw: string): void {
  if (view.busy || slider.disabled) return
  const next = Math.max(0, Math.min(slider.count, Math.trunc(Number(raw)) || 0))
  thumb[slider.id] = next
  dragging = slider.id
  if (slideTimer !== undefined) clearTimeout(slideTimer)
  slideTimer = setTimeout(() => {
    slideTimer = undefined
    if (handle.value === null) return
    emit('opx:panel:slide',
      { handle: handle.value, id: slider.id, index: next, commit: false })
  }, HOVER_MS)
}

/** Let go, or an arrow key pressed: that is the choice, and it does not wait. */
function settleSlot(slider: Slider): void {
  // The drag ends whether or not the commit may go out. Returning on `busy` before
  // this left `dragging` naming the slot, so the caller's own index was ignored for
  // it from then on and the thumb sat on an uncommitted preview.
  if (slideTimer !== undefined) clearTimeout(slideTimer)
  slideTimer = undefined
  dragging = null
  if (view.busy || slider.disabled) return
  if (handle.value === null) return
  emit('opx:panel:slide',
    { handle: handle.value, id: slider.id, index: standing(slider), commit: true })
}

/** A number typed straight in: the same choice an arrow press makes, without the
    walk. Committed at once rather than previewed, because typing a number is a
    destination and not a browse -- there is no intermediate value to show.

    THE FIELD IS WRITTEN BACK after clamping. `:value` follows `standing`, so Vue
    repaints whenever the thumb actually moves -- but typing 900 into a range of
    12 lands on 12, and if the thumb was ALREADY on 12 nothing changed and the
    box would sit there reading 900. */
function jumpSlot(slider: Slider, field: HTMLInputElement): void {
  if (view.busy || slider.disabled) return
  const raw = field.value.trim()
  // An empty box is somebody mid-edit, not a request to wear nothing: `Number('')`
  // is 0, which would silently undress the slot on a backspace.
  if (raw === '') {
    field.value = String(standing(slider))
    return
  }
  const wanted = Math.trunc(Number(raw))
  if (!Number.isFinite(wanted)) {
    field.value = String(standing(slider))
    return
  }

  const next = Math.max(0, Math.min(slider.count, wanted))
  field.value = String(next)
  thumb[slider.id] = next
  if (slideTimer !== undefined) clearTimeout(slideTimer)
  slideTimer = undefined
  dragging = null
  if (handle.value === null) return
  emit('opx:panel:slide', { handle: handle.value, id: slider.id, index: next, commit: true })
}

function press(button: Button): void {
  if (button.disabled || view.busy) return
  emit('opx:panel:action', { handle: handle.value, id: button.id })
}

function filter(value: string): void {
  query.value = value
}
</script>

<template>
  <div class="room" :class="{ open }">
    <!-- NO SCRIM, AND THAT IS THE POINT OF THE SCREEN. The old one covered the
         whole surface with `--op-plate-quiet` and defended it: "a panel is read
         for as long as it takes to choose something". True of a list of elevator
         floors; false of a fitting room, where the thing being chosen is only
         visible THROUGH the panel. The body is the content. If a second caller
         ever needs a wash behind a long read, it belongs on that caller's spec,
         not on every panel. -->

    <!-- THE COLUMN IS ON THE LEFT AND HINGED THERE. `.op-plane` carries the
         perspective and the containment; `.op-anchor-left` is what makes the
         tilt +7deg about the left edge rather than a spin about the middle.

         It is the screen for a caller that sent ITEMS. A caller that sent
         sliders kept its lists, so there is no window to draw, no tab to
         switch, nothing to search and no summary to read: the slot bar below
         is that caller's whole screen. -->
    <section v-if="!view.sliders.length" class="column op-plane op-anchor-left op-ink">
      <div class="bay op-bay op-arete" data-augmented-ui="tr-clip bl-clip border">
        <!-- NO INTERLACE. It exists to stop an unfilled frame reading as a web
             page floating in the air, and it earned its place over a plate. With
             the plate gone it is stripes over the player's own body, which is the
             fill this pass is removing -- the frame and the lit leading edge are
             what hold the surface down now. -->
        <div class="bay-inner">
          <!-- THE TAB STRIP IS THE HEADING. Seven named slots, each saying
               whether something is on it, is a better answer to "what is this
               screen" than the word WARDROBE was. -->
          <nav v-if="view.tabs.length" class="tabs">
            <button
              v-for="tab in view.tabs"
              :key="tab.id"
              type="button"
              class="tab op-frame"
              :class="{ 'is-on': tab.id === currentTab, 'is-off': tab.disabled }"
              :disabled="tab.disabled"
              data-augmented-ui="tr-clip border"
              @click="chooseTab(tab.id)"
            >
              {{ tab.label }}
              <!-- A slot with something on it. A mark, not a frame: what is not a
                   control does not get one. -->
              <span v-if="tab.marked" class="mark" aria-hidden="true">&bull;</span>
            </button>
          </nav>

          <p v-if="view.intro" class="intro op-copy">{{ view.intro }}</p>

          <label
            v-if="view.search !== false"
            class="field op-frame"
            data-augmented-ui="tr-clip border"
          >
            <span class="field-label op-eyebrow">{{ label('search') }}</span>
            <input
              class="field-entry"
              type="text"
              :value="query"
              :placeholder="searchPlaceholder"
              @input="filter(($event.target as HTMLInputElement).value)"
            >
          </label>

          <!-- THE DIAL. Only drawn when there is somewhere to travel: one piece
               is not a range, and a track with a thumb that cannot move is a
               control that lies about what it does. -->
          <div
            v-if="shown.length > 1"
            class="dial op-frame"
            :class="{ 'is-off': view.busy }"
            data-augmented-ui="tr-clip border"
          >
            <input
              class="dial-track"
              type="range"
              min="0"
              :max="shown.length - 1"
              step="1"
              :value="at"
              :disabled="view.busy"
              :aria-label="view.summary?.label ?? ''"
              :aria-valuetext="shown[at]?.label ?? ''"
              @input="scrub(($event.target as HTMLInputElement).value)"
              @change="settle"
            >
          </div>

          <div ref="gridEl" class="grid" :class="{ busy: view.busy }" :style="gridStyle">
            <!-- MEMOISED ON WHAT A ROW SHOWS (#115). The dial moves `at` on every
                 input event of a drag, and without the memo every row of the
                 window was rebuilt for it; now a row is redrawn only when its own
                 chosen, cursor or disabled state, or its words, change. Anything
                 added to this row must be added to the memo too. -->
            <button
              v-for="(item, offset) in visible"
              :key="item.id"
              v-memo="[item.id === chosen, item.id !== chosen && windowStart + offset === at,
                       item.disabled || view.busy, item.label, item.detail]"
              type="button"
              class="row op-frame"
              :class="{
                'is-on': item.id === chosen,
                'op-lift': item.id === chosen,
                'is-hover': item.id !== chosen && windowStart + offset === at,
                'is-off': item.disabled || view.busy
              }"
              :disabled="item.disabled || view.busy"
              data-augmented-ui="tr-clip border"
              @click="pick(item)"
              @mouseenter="pointAt(item.id)"
              @mouseleave="pointAway"
            >
              <span class="row-label op-label op-truncate">{{ item.label }}</span>
              <span v-if="item.detail" class="row-hint op-copy op-truncate">{{ item.detail }}</span>
            </button>

            <p v-if="!visible.length" class="empty op-copy">
              {{ label(view.loading ? 'loading' : 'empty') }}
            </p>
          </div>

          <!-- A READOUT, SO NO FRAME. Where the window sits in the list, and the
               one mark that says the runtime is still working. -->
          <div v-if="count || view.busy" class="readout">
            <span class="count op-value">{{ count }}</span>
            <!-- NOT augmented, and never will be: a clip is recomputed as the
                 element turns, so a spinner is the one shape that pays for the
                 cut on every frame of its animation. -->
            <span v-if="view.busy" class="spinner" aria-hidden="true" />
          </div>

          <!-- WHAT IS ON THE SLOT, next to the buttons that commit it, because
               this is the line a player reads before pressing Save. It used to
               sit above the search field, which is where you look when you have
               not chosen yet. -->
          <div v-if="view.summary" class="summary">
            <div class="plate">
              <span class="plate-label op-eyebrow">{{ view.summary.label }}</span>
              <span class="plate-value op-value op-truncate">{{ view.summary.value }}</span>
            </div>
            <button
              v-if="summaryAction"
              type="button"
              class="row button op-frame"
              :class="{ 'is-off': summaryAction.disabled || view.busy }"
              :disabled="summaryAction.disabled || view.busy"
              data-augmented-ui="tr-clip border"
              @click="press(summaryAction)"
            >
              <span class="row-label op-label op-truncate">{{ summaryAction.label }}</span>
            </button>
          </div>

          <p v-if="view.status" class="status op-copy" :class="view.status.kind">
            {{ view.status.text }}
          </p>
        </div>

        <footer v-if="view.actions.length" class="foot">
          <button
            v-for="button in view.actions"
            :key="button.id"
            type="button"
            class="row button grow op-frame"
            :class="{
              'is-on': button.primary,
              'op-lift': button.primary && !button.disabled && !view.busy,
              'is-off': button.disabled || view.busy
            }"
            :disabled="button.disabled || view.busy"
            data-augmented-ui="tr-clip border"
            @click="press(button)"
          >
            <span class="row-label op-label op-truncate">{{ button.label }}</span>
          </button>
        </footer>
      </div>
    </section>

    <!-- THE TOOL CLUSTER FOR AN ITEMS CALLER, BOTTOM RIGHT. The fitting room no
         longer comes through here -- its view buttons are the row at the top of
         the rail below -- but `tools` is a contract field and a second caller may
         still send one, so the cluster stays where it was. It draws the same
         glyph the rail does when a button carries one. -->
    <div v-if="view.tools.length && !view.sliders.length"
         class="tools op-plane op-anchor-right op-ink">
      <div class="tool-row op-bay op-arete is-end" data-augmented-ui="tr-clip bl-clip border">
        <button
          v-for="button in view.tools"
          :key="button.id"
          type="button"
          class="row button tool op-frame"
          :class="{ 'is-off': button.disabled || view.busy }"
          :disabled="button.disabled || view.busy"
          data-augmented-ui="tr-clip border"
          @click="press(button)"
        >
          <svg v-if="button.icon" class="row-icon" viewBox="0 0 24 24" aria-hidden="true">
            <path
              v-for="(d, n) in GLYPHS[button.icon]"
              :key="n"
              :d="d"
              fill="none"
              stroke="currentColor"
              stroke-width="1.6"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
          <span class="row-label op-label op-truncate">{{ button.label }}</span>
        </button>
      </div>
    </div>

    <!-- =====================================================================
         THE RAIL. The whole left side of the screen, floor to ceiling, for a
         caller that sent sliders.

         WHY THE LEFT SIDE AND NOT THE BOTTOM, which is where this was. The
         owner: "pour le menu de custom perso des vetements je le veux sur la
         gauche, plus en bas au centre car cela cache le joueur" -- and then,
         asked how much room it could have, "tu peux prendre tout le cote gauche
         de l'ecran". A bar along the bottom is the one place that cannot grow:
         a grid of garments needs HEIGHT to scroll in, and the bottom of the
         screen is where the body's legs are.

         AND THIS IS ALSO THE CAMERA DECISION, not a separate one. The obvious
         other half of "the panel takes the left" is "so move the character to
         the right", and on this build that cannot be done: `Open77.camera.detach`
         places the camera at an offset in the body's own space and frames the
         body from there, `Open77.camera.orbit` is a yaw inside the third-person
         rig, and neither takes an aim point -- the only native that would is the
         `camera.script` rig, which `config/appearance.lua` deliberately refuses
         to take a permission for in a clothing shop. A centred subject is what
         the fitting room gets. So the framing is settled HERE instead: the rail
         is bounded at `38vw` rather than half the screen, which on a 16:9 frame
         stops short of where a whole-body shot at 2.6 m begins. Widening this
         past the shot is the same bug as putting the panel over the body, in a
         different file.
         ================================================================== -->
    <section v-if="view.sliders.length" class="rail op-plane op-anchor-left op-ink">
      <div class="rail-bay op-bay op-arete" data-augmented-ui="tr-clip bl-clip border">
        <div class="rail-inner">
          <!-- THE VIEW BUTTONS, AT THE TOP AND ABOVE THE CATEGORIES, which is
               where the owner put them: "refait completement les buttons pour
               changer la view du perso, front etc... place les en forme de
               buttons avec icon au dessus des categories."

               WHAT WAS BROKEN. They were four word-buttons in a `.tool-row`
               pinned to the bottom-right corner of the screen, laid out by
               `.tool { min-width: 78px }` inside a cluster that had its own
               plane, its own hinge and an `.is-end` mirror -- three coordinate
               systems for four buttons, in the one corner a centred bar reaches
               on a narrow screen. Two of the four were not even translated: the
               literal strings `left` and `right` went to the page in both
               languages. This is a rebuild and not a patch: one row, at the top
               of the one column, each button a square with the glyph over the
               word, and nothing positioned absolutely. -->
          <div v-if="view.tools.length" class="views">
            <button
              v-for="button in view.tools"
              :key="button.id"
              type="button"
              class="view-btn op-frame"
              :class="{ 'is-off': button.disabled || view.busy }"
              :disabled="button.disabled || view.busy"
              data-augmented-ui="tr-clip border"
              :title="button.label"
              @click="press(button)"
            >
              <!-- 24x24, stroke only, `currentColor`: the glyph contract. No
                   `filter` anywhere near it -- see `.op-lift`. -->
              <svg
                v-if="button.icon"
                class="view-icon"
                viewBox="0 0 24 24"
                aria-hidden="true"
              >
                <path
                  v-for="(d, n) in GLYPHS[button.icon]"
                  :key="n"
                  :d="d"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.6"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
              </svg>
              <span class="view-label op-eyebrow op-truncate">{{ button.label }}</span>
            </button>
          </div>

          <!-- THE OTHER SCREENS IN HERE: saved outfits, share codes, a shop's
               ready-made looks. Under the view buttons because that is the order
               the owner named them in, and because these LEAVE this screen while
               the row above only turns the body round. -->
          <div v-if="view.groups.length" class="cats">
            <button
              v-for="button in view.groups"
              :key="button.id"
              type="button"
              class="row button cat op-frame"
              :class="{ 'is-off': button.disabled || view.busy }"
              :disabled="button.disabled || view.busy"
              data-augmented-ui="tr-clip border"
              @click="press(button)"
            >
              <span class="row-label op-label op-truncate">{{ button.label }}</span>
            </button>
          </div>

          <!-- THE CATEGORIES. One slot open at a time, which is the change: seven
               tracks stacked down a bar is seven instruments to read, and a
               player dressing a character is doing one slot at a time anyway. The
               dot says the slot has something on it, so the six that are closed
               still state the one fact about themselves that matters. -->
          <nav v-if="view.tabs.length" class="tabs">
            <button
              v-for="tab in view.tabs"
              :key="tab.id"
              type="button"
              class="tab op-frame"
              :class="{ 'is-on': tab.id === currentTab, 'is-off': tab.disabled }"
              :disabled="tab.disabled"
              data-augmented-ui="tr-clip border"
              @click="chooseTab(tab.id)"
            >
              {{ tab.label }}
              <span v-if="tab.marked" class="mark" aria-hidden="true">&bull;</span>
            </button>
          </nav>

          <p v-if="view.intro" class="lead op-copy">{{ view.intro }}</p>
          <p v-if="view.status" class="status op-copy" :class="view.status.kind">
            {{ view.status.text }}
          </p>

          <!-- =============================================================
               THE PICKER. "mettre des box avec l'image du vetement uniquement,
               de sorte a rendre le choix plus facile -- donc il scroll pour
               descendre et voir plus."

               A BOX IS A PICTURE AND A NAME UNDER IT, and the name is not
               decoration: a dozen colourways of one jacket are a dozen nearly
               identical pictures, and the item's own name is what tells them
               apart. A record the garment data has no picture for draws a
               monogram over a name made from the record -- the same fallback
               `InventorySlot` takes for an item whose file is missing.

               IT IS NOT THE WHOLE CATEGORY. The page holds the window it has
               been sent and asks for the next one on the way down; see `Tiles`.
               ========================================================== -->
          <div
            v-if="openSlider"
            ref="tilesEl"
            class="tiles"
            :class="{ busy: view.busy }"
            @scroll.passive="onTilesScroll"
          >
            <!-- NOTHING IS A BOX LIKE ANY OTHER, and it is first and always
                 there. Index 0 on the track is how a slot is emptied, and a
                 player looking at a wall of jackets has nowhere else to say "none
                 of them" -- the track can do it, but the track is not what they
                 are looking at. -->
            <button
              type="button"
              class="tile none op-frame"
              :class="{
                'is-on': standing(openSlider) === 0,
                'is-off': openSlider.disabled || view.busy
              }"
              :disabled="openSlider.disabled || view.busy"
              data-augmented-ui="tr-clip border"
              @click="pickTile(0)"
            >
              <span class="tile-art"><span class="tile-mono">&minus;</span></span>
              <span class="tile-name op-eyebrow">{{ label('nothing') }}</span>
            </button>

            <!-- MEMOISED ON WHAT A BOX SHOWS (#115). A thumb dragged on the track
                 below writes `thumb` on every input event, and `standing()` reads
                 it, so without the memo all of the category's boxes -- up to 677 --
                 were rebuilt per event to move one `is-on`. Now only the box
                 leaving the thumb and the one arriving under it are. Anything added
                 to this box must be added to the memo too. -->
            <button
              v-for="box in boxes"
              :key="box.index"
              v-memo="[standing(openSlider) === box.index, openSlider.disabled || view.busy,
                       box.label, box.name, box.image, broken[box.name] === true]"
              type="button"
              class="tile op-frame"
              :class="{
                'is-on': standing(openSlider) === box.index,
                'is-off': openSlider.disabled || view.busy
              }"
              :disabled="openSlider.disabled || view.busy"
              data-augmented-ui="tr-clip border"
              :title="box.label"
              @click="pickTile(box.index)"
            >
              <span class="tile-art">
                <img
                  v-if="box.image && !broken[box.name]"
                  :src="art(box.name, box.image)"
                  alt=""
                  draggable="false"
                  loading="lazy"
                  @error="artBroken(box.name)"
                >
                <span v-else class="tile-mono">{{ monogram(box.label) }}</span>
              </span>
              <span class="tile-name op-eyebrow">{{ box.label }}</span>
            </button>

            <!-- Also while the category's FIRST window is on its way: the old grid goes
                 at once on a tab change, and with only "Nothing" left in it the category
                 read as empty until the boxes landed. -->
            <p
              v-if="moreToLoad || (openSlider.count > 0 && tiles.slot !== openSlider.id)"
              class="tile-more op-copy"
            >
              {{ label('loading') }}
            </p>
          </div>

          <!-- THE TRACK STAYS, AND IT IS NOT LEFTOVER SLIDER. A category holds up
               to 677 records and the grid reaches them sixty at a time, so
               "position 412" is a scroll of seven windows -- while the track and
               the number box beside it get there in one gesture. It is also the
               control for a category whose boxes are monograms, which is any
               record without a picture. One track, for the open category only: seven of
               them down a column is the bar this screen replaced. -->
          <div
            v-if="openSlider && openSlider.count > 0"
            class="slot op-frame"
            :class="{
              'is-on': standing(openSlider) > 0 && !openSlider.disabled && !view.busy,
              'is-off': openSlider.disabled || view.busy
            }"
            data-augmented-ui="tr-clip border"
          >
            <span class="slot-value op-value op-truncate">{{ openSlider.value }}</span>
            <input
              class="slot-track"
              type="range"
              min="0"
              :max="openSlider.count"
              step="1"
              :value="standing(openSlider)"
              :disabled="openSlider.disabled || view.busy"
              :aria-label="openSlider.label"
              :aria-valuetext="openSlider.value"
              @input="scrubSlot(openSlider, ($event.target as HTMLInputElement).value)"
              @change="settleSlot(openSlider)"
            >
            <label class="slot-step op-frame" data-augmented-ui="tr-clip border">
              <input
                class="slot-number op-eyebrow"
                type="number"
                inputmode="numeric"
                min="0"
                :max="openSlider.count"
                :value="standing(openSlider)"
                :disabled="openSlider.disabled || view.busy"
                :aria-label="openSlider.label"
                @keydown.stop
                @keyup.enter="jumpSlot(openSlider, $event.target as HTMLInputElement)"
                @change="jumpSlot(openSlider, $event.target as HTMLInputElement)"
              >
              <span class="slot-of op-eyebrow">/ {{ openSlider.count }}</span>
            </label>
          </div>
        </div>

        <footer v-if="view.actions.length" class="foot">
          <button
            v-for="button in view.actions"
            :key="button.id"
            type="button"
            class="row button grow op-frame"
            :class="{
              'is-on': button.primary,
              'op-lift': button.primary && !button.disabled && !view.busy,
              'is-off': button.disabled || view.busy
            }"
            :disabled="button.disabled || view.busy"
            data-augmented-ui="tr-clip border"
            @click="press(button)"
          >
            <span class="row-label op-label op-truncate">{{ button.label }}</span>
          </button>
        </footer>
      </div>
    </section>

    <div v-if="dialog" class="confirm">
      <!-- THE ONE FILL LEFT ON THIS SURFACE, and it stays. A yes-or-no question
           over a live street is the one thing here that must not be read
           through. It is also the one surface that takes no tilt: rotating a
           centred plane about its middle is paper on a spindle. -->
      <div class="scrim" />
      <div class="dialog op-ink">
        <section class="bay op-bay op-arete" data-augmented-ui="tr-clip bl-clip border">
          <div class="bay-inner">
            <h2>{{ dialog.title }}</h2>
            <p class="ask op-copy">{{ dialog.text }}</p>
          </div>
          <footer class="foot">
            <button
              type="button"
              class="row button grow op-frame"
              data-augmented-ui="tr-clip border"
              @click="answer(false)"
            >
              <span class="row-label op-label op-truncate">{{ dialog.no }}</span>
            </button>
            <button
              type="button"
              class="row button grow op-frame is-on op-lift"
              data-augmented-ui="tr-clip border"
              @click="answer(true)"
            >
              <span class="row-label op-label op-truncate">{{ dialog.yes }}</span>
            </button>
          </footer>
        </section>
      </div>
    </div>
  </div>
</template>

<style scoped>
.room {
  position: absolute;
  inset: 0;
  opacity: 0;
  pointer-events: none;
  transition: opacity var(--op-dur) var(--op-ease);
}

.room.open {
  opacity: 1;
  pointer-events: auto;
}

/* =============================================================================
   THE TWO CLUSTERS.

   Both are positioned wrappers carrying `.op-plane`, which owns the perspective
   and the paint containment; the anchor class only says which edge it is hinged
   on. EVERY OFFSET PAYS THE BLEED BACK -- `.op-plane` pads by `--op-bleed` so a
   bloom has room inside the containment, and padding moves the wrapper, so each
   offset subtracts exactly what it added.
   ========================================================================== */
.column {
  position: absolute;
  left: calc(var(--op-inset-x) - var(--op-bleed));
  top: calc(var(--op-inset-y) - var(--op-bleed));
  bottom: calc(var(--op-inset-y) - var(--op-bleed));
  /* Narrow on purpose. The drawer was 600px and the body was behind it. */
  width: 420px;
  display: flex;
}

.tools {
  position: absolute;
  right: calc(var(--op-inset-x) - var(--op-bleed));
  bottom: calc(var(--op-inset-y) - var(--op-bleed));
  display: flex;
}

/* Neither cluster fades on its own: `.room` above owns the opacity and the
   pointer for the whole surface, and a second transition on each would be two
   curves running the same change at different speeds. */

/* NO GROUND ON THE ENCLOSURE, and this is the last of the three passes that
   argument has taken. The scrim went first, then the wash over the whole
   surface, and the plate on this bay was what was left: the body is the content
   of this screen and a filled column stands in front of it. The frame stays --
   the cut corners and the lit leading edge are what say this is a surface rather
   than text lying on the street -- and the ground goes where the contract puts
   it, under the type: every row, tab and button here is an `.op-frame` and
   carries its own. */
.bay {
  display: flex;
  flex: 1;
  flex-direction: column;
  min-height: 0;
  min-width: 0;
}

/* THE ONE FILL LEFT, and the file already says why: a yes-or-no question over a
   live street is the one thing here that must not be read through. It is scoped
   to the dialog now, because the bay above no longer has one to inherit. */
.dialog .bay {
  background: var(--op-plate);
}

.bay-inner {
  display: flex;
  flex: 1;
  flex-direction: column;
  gap: var(--op-space-3);
  min-height: 0;
  padding: var(--op-space-4);
  padding-top: calc(var(--op-space-4) + var(--op-cut-lg));
}

/* Unfilled for the same reason the column is, and more so: this cluster sits in
   the corner the body is framed against. Its four buttons each carry the ground
   the contract allows. */
.tool-row {
  flex: none;
  display: flex;
  gap: var(--op-space-2);
  padding: var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-lg));
}

.tool {
  flex: none;
  min-width: 78px;
  justify-content: center;
}

.foot {
  display: flex;
  gap: var(--op-space-2);
  padding: var(--op-space-3) var(--op-space-4)
    calc(var(--op-space-3) + var(--op-cut-lg)) var(--op-space-4);
  border-top: 1px solid var(--op-red-idle);
}

.tabs {
  display: flex;
  flex-wrap: wrap;
  gap: var(--op-space-2);
}

.tab {
  display: flex;
  align-items: center;
  gap: var(--op-space-1);
  padding: var(--op-space-2) var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-sm));
  font: 700 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  cursor: pointer;
}

.mark {
  color: var(--op-red);
}

.intro {
  margin: 0;
  color: var(--op-text-dim);
}

/* =============================================================================
   THE DIAL.

   The container carries the shape, as everything here does: augmented-ui needs
   a real element and a slider's track and thumb are user-agent pseudo-elements,
   so the frame is the box around the control and the parts inside it are drawn
   with the tokens by hand. That is the same exception the spinner takes, for the
   same kind of reason.
   ========================================================================== */
.dial {
  display: flex;
  align-items: center;
  padding: var(--op-space-2) var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-sm));
}

/* The track itself is written once for both sliders on this surface -- the
   column's dial and every slot on the bar. It is the vocabulary being shared,
   not the markup: the two are laid out differently, labelled differently and
   answered differently, and only the four pseudo-elements are the same. */
.dial-track,
.slot-track {
  -webkit-appearance: none;
  appearance: none;
  width: 100%;
  height: var(--op-space-5);
  margin: 0;
  background: transparent;
  cursor: pointer;
}

.dial-track:disabled,
.slot-track:disabled {
  cursor: default;
}

/* A 1px rule, not a filled bar: nothing on this surface is filled. */
.dial-track::-webkit-slider-runnable-track,
.slot-track::-webkit-slider-runnable-track {
  height: 1px;
  background: var(--op-red-idle);
}

/* The thumb is a control, so it is a closed box with the top-right corner taken
   off -- by `clip-path` off the same cut token, because a pseudo-element cannot
   carry `data-augmented-ui`. No literal: change `--op-cut-sm` and this follows. */
.dial-track::-webkit-slider-thumb,
.slot-track::-webkit-slider-thumb {
  -webkit-appearance: none;
  appearance: none;
  width: var(--op-space-4);
  height: var(--op-space-5);
  margin-top: calc(var(--op-space-5) / -2);
  border: 2px solid var(--op-red);
  background: var(--op-plate-lit);
  clip-path: polygon(
    0 0,
    calc(100% - var(--op-cut-sm)) 0,
    100% var(--op-cut-sm),
    100% 100%,
    0 100%
  );
}

.dial-track:focus-visible::-webkit-slider-thumb,
.slot-track:focus-visible::-webkit-slider-thumb {
  border-color: var(--op-red-hi);
}

.dial-track:disabled::-webkit-slider-thumb,
.slot-track:disabled::-webkit-slider-thumb {
  border-color: var(--op-text-faint);
}

/* =============================================================================
   THE RAIL: the whole left side of the screen.

   WHAT IT REPLACED. A bar of seven slider rows pinned along the bottom of the
   screen, with the camera buttons stacked above its right end. The owner's two
   messages settle both halves of the change: "je le veux sur la gauche, plus en
   bas au centre car cela cache le joueur", and "tu peux prendre tout le cote
   gauche de l'ecran". A bottom bar cannot hold a grid, because a grid needs
   height and the bottom of the screen is where the legs are.

   RULE 2 STILL APPLIES AND IT POINTS THE OTHER WAY NOW. The bar was a ROW of
   controls and took no enclosure. This is a column that HOLDS controls, a search
   of the screen's whole left edge, and the thing that says where it ends is the
   frame -- the same `.op-bay` the items column has carried all along, with the
   same `.op-arete` leading edge and the same +7deg hinge about the left edge.
   Rule 9's interlace still stays off: the body is behind this surface and
   stripes over it are the fill three passes have now removed.

   THE WIDTH IS THE CAMERA DECISION. `38vw` is not a taste: a whole-body shot at
   `CAMERA_OFFSET.Y = 2.6` puts the figure in the middle fifth of a 16:9 frame,
   and the camera cannot be told to aim anywhere else -- `Open77.camera.detach`
   takes a position and no aim point, `Open77.camera.orbit` is a yaw inside the
   third-person rig, and the one native that could is behind the `camera.script`
   permission `config/appearance.lua` refuses to take for a clothing shop. So the
   panel is what moves. `min(38vw, 620px)` keeps the right edge clear of the
   figure on every aspect ratio a player is likely to have, and `28rem` is the
   floor below which the grid stops fitting two boxes abreast.
   ========================================================================== */
.rail {
  position: absolute;
  left: calc(var(--op-inset-x) - var(--op-bleed));
  top: calc(var(--op-inset-y) - var(--op-bleed));
  bottom: calc(var(--op-inset-y) - var(--op-bleed));
  width: clamp(28rem, 38vw, 620px);
  display: flex;
}

.rail-bay {
  display: flex;
  flex: 1;
  flex-direction: column;
  min-height: 0;
  min-width: 0;
}

.rail-inner {
  display: flex;
  flex: 1;
  flex-direction: column;
  gap: var(--op-space-3);
  min-height: 0;
  padding: var(--op-space-4);
  padding-top: calc(var(--op-space-4) + var(--op-cut-lg));
}

/* =============================================================================
   THE VIEW BUTTONS.

   A row of square picture buttons at the top of the rail, above everything that
   changes what the character wears. They are the only controls here that do not
   touch the clothes, so they read as a header rather than as the first category.

   WHY A GRID AND NOT A FLEX ROW. Four buttons of identical size is the whole
   affordance -- they are one instrument with four positions -- and a flex row
   sizes each one to its own word, so `Front` and `Right` came out different
   widths and the row read as four unrelated buttons. `repeat(4, 1fr)` is what
   makes them a set. The glyph is over the word and not beside it because the
   word is the caption: at this size the picture is what is scanned.

   NO `filter` ANYWHERE. `.op-lift` is a drop-shadow and these sit over a live
   3D view that repaints every frame. The state is the border, which is what
   `--aug-border-bg` is for. */
.views {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: var(--op-space-2);
}

.view-btn {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: var(--op-space-1);
  min-width: 0;
  padding: var(--op-space-2);
  padding-right: calc(var(--op-space-2) + var(--op-cut-sm));
  border: 0;
  background: transparent;
  color: var(--op-text-dim);
  cursor: pointer;
  transition: color var(--op-dur-fast) linear;
}

/* The menu's hover: denser and 1.5px, not lit. Lit red at 2px is what a chosen
   control wears, and a pointer passing over a view button is not a choice. */
.view-btn:hover:not(:disabled),
.view-btn:focus-visible {
  --aug-border-bg: var(--op-red-deep);
  --aug-border-all: 1.5px;
  color: var(--op-text);
  outline: none;
}

.view-btn:disabled {
  color: var(--op-text-faint);
  cursor: default;
}

.view-icon {
  width: 24px;
  height: 24px;
  flex: none;
}

/* The cut is `.op-truncate` on the element and not four declarations here: that
   class exists because these four were written out by hand in twenty-one places
   and had already drifted. What is left is only what is particular to this
   button -- the label may not push the square wider than its grid column. */
.view-label {
  max-width: 100%;
}

/* The other screens reachable from this one. Full width in the column now rather
   than centred over a bar, and wrapping rather than shrinking: a category with a
   long name is still readable on the second line, and an ellipsised one is not. */
.cats {
  display: flex;
  flex-wrap: wrap;
  gap: var(--op-space-2);
}

.cats .cat {
  flex: 1 1 auto;
  width: auto;
  min-width: 9rem;
  justify-content: center;
}

/* Readouts, no frame: neither of them is a control. Left-aligned, because they
   are now in a column of left-aligned things rather than over a centred bar. */
.lead,
.rail .status {
  margin: 0;
  color: var(--op-text-dim);
}

/* =============================================================================
   THE PICKER GRID.

   "des box avec l'image du vetement uniquement, de sorte a rendre le choix plus
   facile -- donc il scroll pour descendre et voir plus."

   `auto-fill` and not a fixed column count: the rail is `38vw`, so how many
   boxes fit is a property of the player's screen and not of this file. The grid
   is the one part of the column that takes the slack, and it is the only thing
   here that scrolls -- the categories, the view buttons and the track stay put
   while it moves, which is what makes them reachable at the four-hundredth
   jacket. */
.tiles {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(6.5rem, 1fr));
  gap: var(--op-space-1);
  align-content: start;
  flex: 1 1 auto;
  min-height: 0;
  overflow-y: auto;
  overscroll-behavior: contain;
  padding-right: var(--op-space-1);
  /* A CEF scrollbar is a Chromium scrollbar drawn over gameplay. */
  scrollbar-width: none;
}

.tiles::-webkit-scrollbar {
  width: 0;
  height: 0;
}

.tiles.busy {
  opacity: 0.55;
  pointer-events: none;
}

.tile {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: var(--op-space-1);
  min-width: 0;
  padding: var(--op-space-2);
  padding-right: calc(var(--op-space-2) + var(--op-cut-sm));
  border: 0;
  background: transparent;
  color: var(--op-text-dim);
  cursor: pointer;
  text-align: left;
  transition: color var(--op-dur-fast) linear;
}

/* HOVER IS THE MENU'S HOVER: denser, not lit. It was the chosen tile's exact frame,
   so a pointer resting on a jacket made it read as the one being worn. */
.tile:hover:not(:disabled):not(.is-on),
.tile:focus-visible:not(.is-on) {
  --aug-border-bg: var(--op-red-deep);
  --aug-border-all: 1.5px;
  color: var(--op-text);
}

.tile:focus-visible {
  outline: none;
}

/* The one on the body. The border says it, not a fill and not a shadow: a fill
   would be the plate this screen spent three passes removing, and a shadow is a
   `filter` over a view that repaints every frame. */
.tile.is-on {
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2px;
  color: var(--op-text);
}

.tile.is-off {
  color: var(--op-text-faint);
  cursor: default;
}

/* A FIXED SQUARE AND NOT THE PICTURE'S OWN SIZE. A record with no picture is a
   monogram, and a grid whose cells were sized by their contents would have every
   row a different height wherever the two mix, and jump as lazy pictures load. The square is the box; what goes in it is centred and contained. */
.tile-art {
  display: flex;
  align-items: center;
  justify-content: center;
  aspect-ratio: 1;
  min-height: 0;
}

/* No drop-shadow on the picture, for the reason `InventorySlot` gives for the
   same rule: a `filter` is affordable on one icon and not on a scrolling grid of
   them over a live 3D view. */
.tile-art img {
  max-width: 100%;
  max-height: 100%;
  object-fit: contain;
}

/* The fallback for a record with no picture, or one that would not load. */
.tile-mono {
  font: 700 var(--op-fs-title) / 1 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  color: currentcolor;
  opacity: 0.7;
}

/* THE NAME IS DRAWN, AND THE OWNER ASKED FOR "l'image du vetement uniquement".
   It is here because pictures are not enough: colourways of one garment are near
   identical boxes, and the item's own name is what tells two of them apart.
   TWO LINES AND THEN ELLIPSIS, WHICH IS WHY IT IS NOT `.op-truncate`. That rule
   cuts at one line and is right everywhere it is used -- a label that wrapped
   would move every row under it while the pointer was still on the one above.
   Nothing here is aimed at while it moves: a grid row is laid out once and the
   clamp is what stops it growing, so two lines is a bound and not a wrap. One
   line would not do: a name is "Kitsch bomber jacket with reinforced lining" and
   the box is six and a half rem, which leaves a word before the ellipsis.
   `overflow-wrap: anywhere` because the fallback, a record name, has no spaces
   to break at. */
.tile-name {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  overflow: hidden;
  overflow-wrap: anywhere;
  color: currentcolor;
}

/* The line that says the grid has not reached the end of the category. It spans
   every column so it sits under the last row rather than in it. */
.tile-more {
  grid-column: 1 / -1;
  margin: 0;
  padding: var(--op-space-2) 0;
  text-align: center;
  color: var(--op-text-faint);
}

/* =============================================================================
   THE TRACK, FOR THE OPEN CATEGORY ONLY.

   Three columns rather than the bar's four: the slot's own name is the tab above
   it now, so the line is the piece under the thumb, the track, and the readout
   you can type into. It keeps the frame, the chamfer and every part of the
   slider's own styling, because it is the same control -- what changed is that
   there is one of it instead of seven.
   ========================================================================== */
.slot {
  display: grid;
  grid-template-columns: minmax(0, 10rem) minmax(0, 1fr) auto;
  align-items: center;
  gap: var(--op-space-2);
  min-width: 0;
  padding: var(--op-space-1) var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-sm));
}

/* What the thumb is standing on, first on the line. The truncation is
   `.op-truncate` in `design-system/surface.css` and not a rule of its own: the
   ellipsis was factored out of eight copies while this was being written, and a
   ninth here would be the drift that change removed. */

/* Narrow enough that the three columns do not fit: the line folds, the name and
   the readout on the first row and the track across the second. No horizontal
   scroll at any width. */
@media (max-width: 720px) {
  .slot {
    grid-template-columns: minmax(0, 1fr) auto;
  }

  .slot-track {
    grid-column: 1 / -1;
  }

  .views {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}

/* Now a control, so it is a closed box like every other one (rule 2). Kept to
   the width of its content and last on the line, which is where the readout
   already sat -- a player who never types into it should not be able to tell it
   changed. */
.slot-step {
  justify-self: end;
  display: flex;
  align-items: baseline;
  gap: var(--op-space-1);
  padding: 0 calc(var(--op-space-2) + var(--op-cut-sm)) 0 var(--op-space-2);
  color: var(--op-text-faint);
  font-variant-numeric: tabular-nums;
}

/* Three digits' worth and no spinners: the arrows a number input draws are a
   second, worse slider sitting beside the real one, and on this surface they
   are also the one piece of chrome nothing in the theme can style. */
.slot-number {
  /* Three digits AND their tracking: the box carries `.op-eyebrow`'s letter-spacing,
     and at a bare 3ch the third digit of a 677-record category scrolled out of it. */
  width: calc(3ch + 3 * var(--op-track-micro));
  margin: 0;
  padding: 0;
  border: 0;
  outline: none;
  background: transparent;
  text-align: right;
  font: inherit;
  font-variant-numeric: tabular-nums;
  color: var(--op-text);
  caret-color: var(--op-red);
  -moz-appearance: textfield;
  appearance: textfield;
}

.slot-number::-webkit-outer-spin-button,
.slot-number::-webkit-inner-spin-button {
  margin: 0;
  -webkit-appearance: none;
  appearance: none;
}

.slot-number:disabled {
  color: var(--op-text-faint);
}

/* The frame answers the keyboard, because the box is small and the caret alone
   is not enough to say what is taking the digits. */
.slot-step:focus-within {
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2px;
  color: var(--op-text-dim);
}

/* The window of names under the dial. One place items are laid out abreast; the
   frame around it is the bay's, and every cell inside is a plain row. */
.grid {
  display: grid;
  grid-template-columns: repeat(var(--columns, 2), minmax(0, 1fr));
  gap: var(--op-space-1);
  align-content: start;
  /* A ZERO BASIS, so the grid's height is the column's remainder and never its
     rows': the window is sized from this height, and a basis of `auto` would let
     the rows it draws feed back into the measurement that chose them (#118). */
  flex: 1 1 0;
  min-height: 0;
  overflow: hidden;
  transition: opacity var(--op-dur-fast) var(--op-ease);
}

.grid.busy {
  opacity: 0.55;
}

.empty {
  grid-column: 1 / -1;
  margin: var(--op-space-4) 0;
  text-align: center;
  font: 400 var(--op-fs-meta) / 1.4 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: var(--op-text-faint);
}

.readout {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
}

.count {
  flex: 1;
  font: 400 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  color: var(--op-text-dim);
  font-variant-numeric: tabular-nums;
}

/* The chosen piece: a readout and a rule, no frame, because it is not a control.
   The one button beside it is. */
.summary {
  display: flex;
  align-items: stretch;
  gap: var(--op-space-2);
  padding-top: var(--op-space-2);
  border-top: 1px solid var(--op-red-idle);
}

.plate {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  min-width: 0;
  justify-content: center;
}

.plate-label {
  color: var(--op-red-idle);
}

.status {
  margin: 0;
  font: 400 var(--op-fs-meta) / 1.4 var(--op-font-mono);
  color: var(--op-text-dim);
}

.status.error {
  color: var(--op-alarm);
}

/* A button is a row with nothing on its right: the label centres and the plate shrinks
   to it. Scoped to this module, so OpRow stays one component and not two. */
.button {
  justify-content: center;
  cursor: pointer;
}

.grow {
  flex: 1;
}

.confirm {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
}

.scrim {
  position: absolute;
  inset: 0;
  background: var(--op-plate-quiet);
}

.dialog {
  position: relative;
  display: flex;
  width: 420px;
}

.dialog h2 {
  margin: 0;
  font: 700 var(--op-fs-title) / 1.15 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  text-transform: uppercase;
  color: var(--op-red);
}

.ask {
  margin: 0;
  font: 400 var(--op-fs-body) / 1.4 var(--op-font-body);
  color: var(--op-text-dim);
}

/* The spinner: a stroke that turns, and the one shape here that is not cut. */
.spinner {
  flex: none;
  width: 14px;
  height: 14px;
  border: 2px solid var(--op-red-idle);
  border-top-color: var(--op-red);
  border-radius: 50%;
  animation: panel-spin 700ms linear infinite;
}

@keyframes panel-spin {
  to {
    transform: rotate(360deg);
  }
}

/* =============================================================================
   A ROW -- label, optional hint. The states come from `.op-frame` and nothing
   about them is restated here.

   There is no shared row component and that is deliberate: a menu row, a target
   row, an inventory cell and a panel row look alike and behave nothing alike.
   What is shared is the vocabulary -- `.op-frame`, `.op-bay`, `.op-arete`, the
   states, the type roles and the ink -- not the markup.
   ========================================================================== */
.row {
  display: flex;
  align-items: center;
  gap: var(--op-space-3);
  width: 100%;
  padding: var(--op-space-2) var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-sm));
  text-align: left;
  cursor: pointer;
  transition: color var(--op-dur-fast) linear;
}

.row:disabled {
  cursor: default;
}

.row-label {
  flex: 0 1 auto;
}

/* A glyph beside a row's words, for the one cluster that still draws buttons in
   a line. Slightly under the 24px the paths are drawn at, so it sits on the cap
   height of the label rather than towering over it. */
.row-icon {
  flex: none;
  width: 18px;
  height: 18px;
}

.row-hint {
  flex: 1 1 auto;
  opacity: 0.7;
}

/* THE ONE FIELD. The caret is the only thing on this surface allowed to blink,
   and the input itself is transparent: the frame and the ground belong to the
   label that wraps it, which is the element that carries the shape. */
.field {
  display: flex;
  align-items: baseline;
  gap: var(--op-space-3);
  padding: var(--op-space-2) var(--op-space-3);
  padding-right: calc(var(--op-space-3) + var(--op-cut-sm));
}

/* The frame answers the keyboard, as `.slot-step` does: the entry has no outline and no
   box of its own, so without this the caret was the only sign the search had focus. */
.field:focus-within {
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2px;
}

.field-label {
  flex: none;
  color: var(--op-red-idle);
}

.field-entry {
  flex: 1;
  min-width: 0;
  margin: 0;
  padding: 0;
  border: 0;
  outline: none;
  background: transparent;
  font: 400 var(--op-fs-body) / 1.3 var(--op-font-body);
  color: var(--op-text);
  caret-color: var(--op-red);
}

.field-entry::placeholder {
  color: var(--op-text-faint);
}
</style>
