<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { list, num, table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE RIPPERDOC -- the base game's 2.0 ripperdoc screen, played by two people.
 *
 * IT DECIDES NOTHING. The server's frame says what the patient wears and what
 * the chair is doing; the Lua view seam lays the tray out from the shared
 * catalogue (every body system with its filled slots, the pieces of the system
 * being browsed, the one piece opened in full) and hands this page ONE PAGE OF
 * FACTS. A fit, an upgrade, a pull and a repair are INTENTS
 * (`ripperdoc:offer`); the body only changes when a fresh frame comes back.
 * Browsing is an intent too (`ripperdoc:browse`), answered locally by the seam.
 *
 * -- WHAT IT LOOKS LIKE, AND WHY IT BREAKS `ui/README.md` ON PURPOSE --
 *
 * The player asked for the clinic to look like the game's own ripperdoc, made
 * the way the game makes it, and not like the rest of this surface. So this
 * one screen follows the base game instead of the OPX language:
 *
 *   * LAYOUT from `base\gameplay\gui\fullscreen\ripperdoc\ripperdoc.inkwidget`
 *     (2.31), in its own 3840x2160 units (`--u`, one unit per 4K pixel): the
 *     hologram body in the middle; the ten systems around it at the widget's
 *     own anchors (frontal cortex, arms, skeleton, nervous and integumentary
 *     systems on the left; operating system, face, hands, circulatory system
 *     and legs on the right); the capacity meter on the left and the armor
 *     meter on the right, fifty bars each on the meters' own backgrounds; a
 *     system opened as the widget's inventory tab -- its name between two
 *     arrows over ten dots, its slots, and the grid.
 *   * ART cut out of the installed game (`tools/ripperdoc-art.py`): the
 *     paperdoll bodies (`woman_body` / `man_body`, one per system), the tile,
 *     tooltip, label and button shapes of `atlas_shapes_sync` /
 *     `atlas_inventory` / `inventory4_atlas`, the meters' backgrounds, the
 *     capacity, armor and eddies icons. The shapes are white, as the game's
 *     are, and tinted here with `-webkit-mask-box-image` sliced where the
 *     atlases slice them.
 *   * THE PARTS the game builds the screen from, one for one: a slot and a
 *     grid piece are its `itemDisplay` (slots.inkwidget) -- no tier or price
 *     written on the tile, and a piece beyond the wallet greyed under the red
 *     cash symbol of its `Money` requirement; the meters' labels sit where
 *     `RipperdocMetersCapacity` moves them; every tooltip is its `itemTooltip`
 *     (itemtooltip.inkwidget), Blue with the `itemEquipped` tab for what the
 *     patient wears; a confirmation is the widget's `purchase_popup`.
 *   * COLOUR from `main_colors.inkstyle` (MainColors.*), the tier colours from
 *     `rarity_menus.inkstyle` (Rarity.*), the meters' states from
 *     `ripperdoc_poor.inkstyle`, the tooltip's from `tooltip_style.inkstyle`.
 *     They are the game's, so the operator's theme does not recolour this
 *     screen -- which is the point of it.
 *   * TYPE: the game's own face, Rajdhani (`raj.inkfontfamily`), at the
 *     widget's sizes (ReadableFontSize 50, ReadableMedium 42, TitleHeader 70),
 *     Semi-Bold for headers and Medium for the rest.
 */

interface Flash {
  key: string
  args: Record<string, unknown>
}

interface Stat {
  key: string
  value: number
}

interface Grade {
  id: string
  name: string
  tier: number
  price: number
  cost: number
  upgrade: boolean
  capacity: number
  owned: boolean
  effects: Stat[]
  stats: Stat[]
  hack: string
  game: string
}

interface Fitted {
  grade: string
  points: number
  state: string
  broken: boolean
  inBody: boolean
  repair: number
  /** Seconds before it breaks at the rate the calendar wears it now; null when it has no clock. */
  left: number | null
  /** Its hard-use allowance, spent and whole, in seconds of its life. */
  wear: number
  wearCap: number
}

interface Detail {
  id: string
  name: string
  desc: string
  /** The base game's own picture of the piece: a file stem under `images/cyberware/`, or ''. */
  icon: string
  kind: string
  system: string
  power: string
  iconic: boolean
  remove: number
  unsold: boolean
  fitted: Fitted | null
  grades: Grade[]
}

interface Piece {
  id: string
  name: string
  kind: string
  icon: string
  iconic: boolean
  tierFrom: number
  tierTo: number
  priceFrom: number
  fitted: string
  /** The tier of the grade worn, when one is. */
  tier: number
  points: number
  state: string
  broken: boolean
}

/** One filled slot on the body. */
interface Slot {
  id: string
  name: string
  icon: string
  tier: number
  state: string
  points: number
  iconic: boolean
}

interface System {
  id: string
  used: number
  slots: number
  worn: Slot[]
}

interface Offer {
  id: number
  mode: string
  entry: string
  grade: string
  name: string
  gradeName: string
  price: number
  by: string
  /** The piece's picture and the offered tier, as the confirmation draws them. */
  icon: string
  tier: number
  iconic: boolean
}

interface Invitee {
  id: number
  name: string
}

const { t, has } = useLocale()

/** The page's own ceilings, repeating Lua's rather than trusting the sender. */
const MAX_SYSTEMS = 12
const MAX_PIECES = 24
const MAX_GRADES = 8
const MAX_SLOTS = 6
const MAX_INVITEES = 8
const MAX_RUN = 6

type Mode = 'sitter' | 'desk' | 'invite' | 'notice'
type Family = 'female' | 'male'

const open = ref(false)
const mode = ref<Mode>('sitter')
const chairName = ref('')
const attended = ref(false)
const busy = ref(false)
const ready = ref(true)
const patientName = ref('')
const seated = ref(false)
const from = ref('')
const wallet = ref<number | null>(null)
const capacityUsed = ref(0)
const capacityMax = ref(0)
const capacityEnforced = ref(true)
const armorNow = ref(0)
const armorMax = ref(0)
const family = ref<Family>('female')
const systems = ref<System[]>([])
const system = ref('')
const pieces = ref<Piece[]>([])
const detail = ref<Detail | null>(null)
const offer = ref<Offer | null>(null)
const invitees = ref<Invitee[]>([])
const inviteOut = ref('')
const flash = ref<Flash | null>(null)

/* -- the page's own state: what the player is looking at, never sent -------- */

/** The paperdoll, or one system opened as the inventory tab. */
const view = ref<'body' | 'system'>('body')
/** The system the pointer is on: its part of the body lights. */
const hovered = ref('')
/** The small tooltip of the slot or grid piece the pointer is on. */
interface HoverTip {
  title: string
  tier: number
  iconic: boolean
  /** Worn by the patient: the game's tooltip in its `Equipped` blue. */
  equipped: boolean
  lines: string[]
  x: number
  y: number
  side: 'left' | 'right'
}
const hoverTip = ref<HoverTip | null>(null)
/** The meter the pointer is on, for its tooltip. */
const meterTip = ref<'' | 'capacity' | 'armor'>('')
/** The tier picked in the opened piece; '' reads as the default one. */
const pickedGrade = ref('')

let release: (() => void) | undefined
let noticeTimer: ReturnType<typeof setTimeout> | undefined

/* -- the game's layout, in its own 4K units ---------------------------------- */

/**
 * Where each system's slots sit around the body: the widget's anchors
 * (`frontalAnchor` ... `legsAnchor`). A left group's right edge and a right
 * group's left edge are at `x`; its label's top is at `y`.
 */
const GROUPS: Record<string, { side: 'left' | 'right'; x: number; y: number }> = {
  frontal_cortex: { side: 'left', x: 1750, y: 300 },
  arms: { side: 'left', x: 1600, y: 600 },
  skeleton: { side: 'left', x: 1450, y: 900 },
  nervous_system: { side: 'left', x: 1750, y: 1200 },
  integumentary: { side: 'left', x: 1750, y: 1500 },
  operating_system: { side: 'right', x: 2250, y: 300 },
  face: { side: 'right', x: 2370, y: 600 },
  hands: { side: 'right', x: 2520, y: 900 },
  circulatory: { side: 'right', x: 2250, y: 1200 },
  legs: { side: 'right', x: 2250, y: 1500 }
}

/** A slot tile: `slotRipperdocDisplay`, 224x202 with the 10-unit gap of the mini grid. */
const TILE_W = 216
const TILE_GAP = 10

interface Layer {
  file: string
  cx: number
  cy: number
  w: number
  h: number
}

/**
 * The paperdoll: each body's parts at the size the atlas carries them and at
 * the centre the widget puts them (`femaleHovers` / `maleHovers`, around the
 * `paperDollWrapper`), one image per system. The full-body ones replace the
 * base; the others lie over it.
 */
function dollOf(prefix: string, body: [number, number, number, number], parts: Record<string, Layer>): {
  base: Layer
  systems: Record<string, Layer>
} {
  const [cx, cy, w, h] = body
  const full = (file: string): Layer => ({ file, cx, cy, w, h })
  return {
    base: full(`${prefix}_base`),
    systems: {
      skeleton: full(`${prefix}_base`),
      nervous_system: full(`${prefix}_nerve`),
      integumentary: full(`${prefix}_skin`),
      circulatory: full(`${prefix}_circ`),
      ...parts
    }
  }
}

const DOLLS: Record<Family, ReturnType<typeof dollOf>> = {
  female: dollOf('f', [1962, 1070, 735, 1782], {
    frontal_cortex: { file: 'f_cortex', cx: 1973, cy: 420, w: 178, h: 333 },
    face: { file: 'f_eye', cx: 1972, cy: 365, w: 163, h: 185 },
    operating_system: { file: 'f_os', cx: 1962, cy: 569, w: 403, h: 668 },
    arms: { file: 'f_arms', cx: 1966, cy: 906, w: 725, h: 438 },
    hands: { file: 'f_hands', cx: 1962, cy: 1023, w: 735, h: 197 },
    legs: { file: 'f_legs', cx: 1969, cy: 1390, w: 341, h: 1070 }
  }),
  male: dollOf('m', [1970, 1095, 1090, 1862], {
    frontal_cortex: { file: 'm_cortex', cx: 1976, cy: 415, w: 205, h: 348 },
    face: { file: 'm_eye', cx: 1970, cy: 356, w: 189, h: 218 },
    operating_system: { file: 'm_os', cx: 1982, cy: 600, w: 509, h: 760 },
    arms: { file: 'm_arms', cx: 1971, cy: 865, w: 916, h: 327 },
    hands: { file: 'm_hands', cx: 1970, cy: 1028, w: 1089, h: 221 },
    legs: { file: 'm_legs', cx: 1959, cy: 1441, w: 533, h: 1094 }
  })
}

/**
 * The meters' fifty bars, read off the game's own backgrounds (`cw_barbg`,
 * `armor_barbg`, 4K): the top of each bar from the top of the art, five blocks
 * of ten, 18 units apart with the widget's 12-unit gap between blocks. The fill
 * climbs from the last.
 */
const BAR_TOPS: number[] = [0, 1, 2, 3, 4].flatMap((block) =>
  Array.from({ length: 10 }, (_, row) => [16, 208, 399, 592, 785][block] + row * 18)
)

/* -- coercion: every list through `list()`, every number through `num()` -- */

function runOf(value: unknown): Stat[] {
  return list<Payload>(value)
    .slice(0, MAX_RUN)
    .map((row) => ({ key: text(row.key), value: num(row.value) }))
    .filter((row) => row.key !== '')
}

function fittedOf(value: unknown): Fitted | null {
  const raw = table(value)
  const grade = text(raw.grade)
  if (!grade) return null
  const left = num(raw.left, -1)
  return {
    grade,
    points: clampPoints(raw.points),
    state: text(raw.state),
    broken: raw.broken === true,
    inBody: raw.pulled !== true,
    repair: num(raw.repair),
    left: left >= 0 ? left : null,
    wear: Math.max(0, num(raw.wear)),
    wearCap: Math.max(0, num(raw.wearCap))
  }
}

function detailOf(value: unknown): Detail | null {
  const raw = table(value)
  const id = text(raw.id)
  if (!id) return null
  const grades: Grade[] = []
  for (const row of list<Payload>(raw.grades).slice(0, MAX_GRADES)) {
    const gradeId = text(row.id)
    if (!gradeId) continue
    grades.push({
      id: gradeId,
      name: text(row.name, gradeId),
      tier: tierOf(row.tier),
      price: num(row.price),
      cost: num(row.cost, num(row.price)),
      upgrade: row.upgrade === true,
      capacity: num(row.capacity),
      owned: row.owned === true,
      effects: runOf(row.effects),
      stats: runOf(row.stats),
      hack: text(row.hack),
      game: text(row.game)
    })
  }
  return {
    id,
    name: text(raw.name, id),
    desc: text(raw.desc),
    icon: iconOf(raw.icon),
    kind: text(raw.kind),
    system: text(raw.system),
    power: text(raw.power),
    iconic: raw.iconic === true,
    remove: num(raw.remove),
    unsold: raw.unsold === true,
    fitted: fittedOf(raw.fitted),
    grades
  }
}

function slotsOf(value: unknown): Slot[] {
  return list<Payload>(value)
    .slice(0, MAX_SLOTS)
    .map((row) => ({
      id: text(row.id),
      name: text(row.name, text(row.id)),
      icon: iconOf(row.icon),
      tier: tierOf(row.tier),
      state: text(row.state),
      points: clampPoints(row.points),
      iconic: row.iconic === true
    }))
    .filter((row) => row.id !== '')
}

/** Condition clamped to its own scale; an absent number reads as fresh. */
function clampPoints(value: unknown): number {
  return Math.max(0, Math.min(100, Math.round(num(value, 100))))
}

/** A tier the game has a colour for: 1 to 5. */
function tierOf(value: unknown): number {
  return Math.max(1, Math.min(5, Math.round(num(value, 1))))
}

/**
 * A piece's picture, as the file stem Lua named (`M.Cyber.PictureFor`: eight hex
 * characters -- a short name keeps the file inside a Windows client's path
 * budget). It becomes part of a URL, so only that spelling gets through; any
 * other text is no picture at all.
 */
function iconOf(value: unknown): string {
  const name = text(value)
  return /^[0-9a-f]{8}$/.test(name) ? name : ''
}

/** Where the pictures live once the build has copied `ui/public`. */
const ICON_BASE = 'images/cyberware/'
/** Where the ripperdoc screen's own art lives (`tools/ripperdoc-art.py`). */
const ART_BASE = 'images/ripperdoc/'

/** The pictures that failed to load this session: drawn as no picture after. */
const brokenIcons = ref<Set<string>>(new Set())

function iconSrc(name: string): string {
  return `${ICON_BASE}${name}.webp`
}

function artSrc(file: string): string {
  return `${ART_BASE}${file}.webp`
}

function hasIcon(name: string): boolean {
  return name !== '' && !brokenIcons.value.has(name)
}

function iconFailed(name: string): void {
  if (brokenIcons.value.has(name)) return
  const next = new Set(brokenIcons.value)
  next.add(name)
  brokenIcons.value = next
}

/**
 * Locale arguments, coerced: `t` takes strings or numbers, nothing else. An
 * argument that IS a catalogue key speaks the player's language (piece, grade
 * and system names and the reasons cross the wire as keys); anything else -- a
 * player name, a host reason -- passes through untouched.
 */
function vars(args: Record<string, unknown>): Record<string, string | number> {
  const out: Record<string, string | number> = {}
  for (const [name, value] of Object.entries(args)) {
    if (typeof value === 'number') {
      out[name] = value
    } else {
      const raw = String(value ?? '')
      out[name] = has(raw) ? t(raw) : raw
    }
  }
  return out
}

function flashText(line: Flash | null): string {
  if (line === null) return ''
  const key = text(line.key)
  return key ? t(key, vars(line.args)) : ''
}

function flashOf(payload: Payload): Flash | null {
  const raw = table(payload.flash)
  const key = text(raw.key)
  return key ? { key, args: table(raw.args) } : null
}

/**
 * The one offer's question, the title of the game's purchase popup ("DO YOU
 * WANT TO BUY THIS ITEM?") in the words of its mode. A repair of a piece the
 * body has pushed out is a refit.
 */
function offerAsk(row: Offer): string {
  if (row.mode === 'upgrade') return t('ripperdoc.ask.upgrade')
  if (row.mode === 'remove') return t('ripperdoc.ask.remove')
  if (row.mode === 'repair') {
    const piece = detail.value
    const pulled = piece !== null && piece.id === row.entry && piece.fitted !== null && !piece.fitted.inBody
    return t(pulled ? 'ripperdoc.ask.refit' : 'ripperdoc.ask.repair')
  }
  return t('ripperdoc.ask.install')
}

/** Eddies grouped in threes, as the game's tooltips write a price ("10 000"). */
function money(value: number): string {
  const whole = Math.max(0, Math.round(value))
  return String(whole).replace(/\B(?=(\d{3})+(?!\d))/g, ' ')
}

/** The tier as the game names it: its rarity's colour class and its label. */
function tierClass(tier: number, iconic = false): string {
  return iconic && tier >= 5 ? 'is-iconic' : `is-t${tierOf(tier)}`
}

/** A tier range, as the grid's row writes it. */
function tiersOf(row: Piece): string {
  return row.tierFrom === row.tierTo
    ? t('ripperdoc.tierOne', { from: row.tierFrom })
    : t('ripperdoc.tiers', { from: row.tierFrom, to: row.tierTo })
}

/** An effect as a line with its number, `noFall` as the words alone. */
function effectText(row: Stat): string {
  const value = Number.isInteger(row.value) ? row.value : Number(row.value.toFixed(2))
  return t('ripperdoc.effect.' + row.key, { value })
}

/** A stat's number, in the units the grade carries it in. */
function statValue(row: Stat): string {
  if (row.key.endsWith('Ms')) return `${(row.value / 1000).toFixed(1)}s`
  return String(row.value)
}

/**
 * How long a piece has left, the way the base game counts down a timer: days
 * and hours while it is days away, hours and minutes on its last day.
 */
function leftText(seconds: number): string {
  const whole = Math.max(0, Math.floor(seconds))
  const hours = Math.floor(whole / 3600)
  if (hours >= 24) {
    return t('ripperdoc.lifeLeft', { days: Math.floor(hours / 24), hours: String(hours % 24).padStart(2, '0') })
  }
  return t('ripperdoc.lifeLeftHours', {
    hours,
    minutes: String(Math.floor((whole % 3600) / 60)).padStart(2, '0')
  })
}

/** Hours of a life, one decimal under ten, whole above. */
function hoursText(seconds: number): string {
  const hours = Math.max(0, seconds) / 3600
  return hours < 10 ? hours.toFixed(1) : String(Math.round(hours))
}

/** A condition's colour: the game's meter states, from whole to gone. */
function conditionClass(state: string, points: number): string {
  if (state === 'broken') return 'is-broken'
  if (state === 'failing' || points < 25) return 'is-failing'
  if (state === 'worn' || points < 75) return 'is-worn'
  return 'is-whole'
}

/* -- who may press what ---------------------------------------------------- */

/** The operator, at the desk with a patient in the chair. */
const operating = computed(() => mode.value === 'desk' && seated.value)

/** The patient, with nobody at the desk. */
const selfService = computed(() => mode.value === 'sitter' && !attended.value)

/** Whether any chrome control is live right now. */
const canAct = computed(() => (operating.value || selfService.value) && !busy.value && offer.value === null)

/** The body a platform implant needs cannot be read: those grades wait. */
function blockedByRecord(kind: string): boolean {
  return !ready.value && (kind === 'implant' || kind === 'ice')
}

/** The screen shows a body: the patient's own, or the one in the operator's chair. */
const showsBody = computed(() => mode.value === 'sitter' || (mode.value === 'desk' && seated.value))

/* -- the body ------------------------------------------------------------- */

const doll = computed(() => DOLLS[family.value])

/** The part of the body the pointer's system lights, if any. */
const litLayer = computed<Layer | null>(() => {
  const id = hovered.value
  if (id === '') return null
  return doll.value.systems[id] ?? null
})

/** Whether the lit part replaces the whole body rather than lying over it. */
const litIsFull = computed(() => litLayer.value !== null && litLayer.value.w === doll.value.base.w)

/** A layer's box, in the stage's units. */
function layerStyle(layer: Layer, scale = 1, dx = 0, dy = 0): Record<string, string> {
  const w = layer.w * scale
  const h = layer.h * scale
  return {
    left: `calc(${layer.cx + dx - w / 2} * var(--u))`,
    top: `calc(${layer.cy + dy - h / 2} * var(--u))`,
    width: `calc(${w} * var(--u))`,
    height: `calc(${h} * var(--u))`
  }
}

interface Group {
  system: System
  side: 'left' | 'right'
  style: Record<string, string>
  cells: (Slot | null)[]
}

/** Every system the body has an anchor for, with its slots filled in order. */
const groups = computed<Group[]>(() =>
  systems.value
    .filter((row) => GROUPS[row.id] !== undefined)
    .map((row) => {
      const anchor = GROUPS[row.id]
      const count = Math.max(1, Math.min(MAX_SLOTS, Math.max(row.slots, row.worn.length)))
      const width = count * TILE_W + (count - 1) * TILE_GAP
      const left = anchor.side === 'left' ? anchor.x - width : anchor.x
      const cells: (Slot | null)[] = []
      for (let index = 0; index < count; index++) cells.push(row.worn[index] ?? null)
      return {
        system: row,
        side: anchor.side,
        style: { left: `calc(${left} * var(--u))`, top: `calc(${anchor.y} * var(--u))`, width: `calc(${width} * var(--u))` },
        cells
      }
    })
)

/** The system opened as the inventory tab, and its place among the others. */
const openIndex = computed(() => systems.value.findIndex((row) => row.id === system.value))
const openSystem = computed<System | null>(() => systems.value[openIndex.value] ?? null)
const openCells = computed<(Slot | null)[]>(() => {
  const row = openSystem.value
  if (row === null) return []
  const count = Math.max(1, Math.min(MAX_SLOTS, Math.max(row.slots, row.worn.length)))
  const cells: (Slot | null)[] = []
  for (let index = 0; index < count; index++) cells.push(row.worn[index] ?? null)
  return cells
})

/** The opened system's part of the body, drawn large beside the grid. */
const zoomLayer = computed<Layer | null>(() => doll.value.systems[system.value] ?? null)
const zoomStyle = computed<Record<string, string>>((): Record<string, string> => {
  const layer = zoomLayer.value
  if (layer === null) return {}
  const scale = Math.min(1.6, 1500 / layer.h, 640 / layer.w)
  const w = layer.w * scale
  const h = layer.h * scale
  return {
    left: `calc(${2880 - w / 2} * var(--u))`,
    top: `calc(${1130 - h / 2} * var(--u))`,
    width: `calc(${w} * var(--u))`,
    height: `calc(${h} * var(--u))`
  }
})

/* -- the piece opened ------------------------------------------------------ */

/** The tier the opened piece shows: the one picked, else the worn one, else the first. */
const grade = computed<Grade | null>(() => {
  const piece = detail.value
  if (piece === null || piece.grades.length === 0) return null
  return (
    piece.grades.find((row) => row.id === pickedGrade.value) ??
    piece.grades.find((row) => row.owned) ??
    piece.grades[0]
  )
})

/** The grade worn of the opened piece, if any. */
const wornGrade = computed<Grade | null>(() => detail.value?.grades.find((row) => row.owned) ?? null)

/** Whether the tier shown is the one the patient wears: the tooltip's `Equipped` state. */
const shownInstalled = computed(() => grade.value !== null && grade.value.owned && detail.value !== null && detail.value.fitted !== null)

/**
 * What the shown grade would change on the meters: the capacity it adds (the
 * worn grade's taken back on an upgrade) and the plating. Nothing for the grade
 * already worn.
 */
const preview = computed(() => {
  const shown = grade.value
  const piece = detail.value
  if (shown === null || piece === null || shown.owned) return { capacity: 0, armor: 0 }
  const worn = wornGrade.value
  const armorOf = (row: Grade | null): number => row?.effects.find((stat) => stat.key === 'armor')?.value ?? 0
  return {
    capacity: shown.capacity - (worn?.capacity ?? 0),
    armor: Math.round(armorOf(shown) - armorOf(worn))
  }
})

/** What the primary button says and does for the shown grade. */
const primary = computed(() => {
  const piece = detail.value
  const shown = grade.value
  if (piece === null || shown === null) return null
  if (shown.owned && piece.fitted !== null) {
    return { label: piece.fitted.broken ? t('ripperdoc.broken') : t('ripperdoc.installed'), price: null, live: false }
  }
  const worn = wornGrade.value
  const upgrade = shown.upgrade && worn !== null && shown.price > worn.price
  const live = canAct.value && !blockedByRecord(piece.kind) && !piece.unsold
  // At the desk the press is a proposal: the patient's confirmation decides it.
  return {
    label: operating.value ? t('ripperdoc.act.propose') : upgrade ? t('ripperdoc.act.upgrade') : t('ripperdoc.act.install'),
    price: shown.cost,
    live
  }
})

const capacityFull = computed(() => capacityEnforced.value && capacityUsed.value >= capacityMax.value)

/* -- the meters ----------------------------------------------------------- */

interface Bar {
  top: number
  state: string
}

/** How many of the fifty bars `value` of `max` fills. */
function barsFor(value: number, max: number): number {
  if (max <= 0) return 0
  return Math.max(0, Math.min(50, Math.round((value / max) * 50)))
}

/**
 * The capacity meter's bars in the game's own states: what is taken
 * (`Safe_Default`, yellow), what the shown grade would add (`Safe_Add`, green)
 * or give back (`Safe_Remove`), and everything past the limit red.
 */
const capacityBars = computed<Bar[]>(() => {
  const max = capacityMax.value
  const used = barsFor(capacityUsed.value, max)
  const after = barsFor(capacityUsed.value + preview.value.capacity, max)
  const over = capacityEnforced.value && capacityUsed.value + preview.value.capacity > max
  return BAR_TOPS.map((top, index) => {
    const fromBottom = 49 - index
    let state = ''
    if (fromBottom < used) state = 'is-used'
    if (preview.value.capacity > 0 && fromBottom >= used && fromBottom < after) state = over ? 'is-over' : 'is-add'
    if (preview.value.capacity < 0 && fromBottom >= after && fromBottom < used) state = 'is-remove'
    if (capacityUsed.value > max && max > 0 && state === 'is-used') state = 'is-over'
    return { top, state }
  })
})

/** The top of the fill, in the art's units. */
function levelTop(bars: number): number {
  const index = Math.max(0, Math.min(49, 50 - Math.max(1, bars)))
  return BAR_TOPS[index]
}

/**
 * Where a meter's two labels sit, as the game's own meters put them
 * (`RipperdocMetersCapacity.ConfigureBar` and `MoveLabelToBar`, 2.31): what is
 * hangs from the top of the fill; what the shown tier would add sits right on
 * top of it, and what it would give back hangs right under it. A label is 50
 * units high, the bars 18 apart. On a full meter an addition goes under too:
 * there is no bar left above to sit on.
 */
function labelTops(level: number, change: number): { now: number; cost: number } {
  const now = level - 9
  const above = level - 18 - 50
  return { now, cost: change > 0 && above >= -10 ? above : now + 54 }
}

const capacityLevel = computed(() => levelTop(barsFor(capacityUsed.value, capacityMax.value)))
const capacityLabels = computed(() => labelTops(capacityLevel.value, preview.value.capacity))

/** The armor meter: the plating now, and what the shown grade would add. */
const armorBars = computed<Bar[]>(() => {
  const max = armorMax.value
  const now = barsFor(armorNow.value, max)
  const after = barsFor(Math.min(max, armorNow.value + preview.value.armor), max)
  return BAR_TOPS.map((top, index) => {
    const fromBottom = 49 - index
    let state = ''
    if (fromBottom < now) state = now >= 40 ? 'is-high' : now >= 15 ? 'is-mid' : 'is-low'
    if (preview.value.armor > 0 && fromBottom >= now && fromBottom < after) state = 'is-add'
    if (preview.value.armor < 0 && fromBottom >= after && fromBottom < now) state = 'is-remove'
    return { top, state }
  })
})

const armorLevel = computed(() => levelTop(barsFor(armorNow.value, armorMax.value)))
const armorLabels = computed(() => labelTops(armorLevel.value, preview.value.armor))

/* -- intents --------------------------------------------------------------- */

function blank(): void {
  open.value = false
  systems.value = []
  pieces.value = []
  detail.value = null
  offer.value = null
  invitees.value = []
  inviteOut.value = ''
  flash.value = null
  busy.value = false
  patientName.value = ''
  seated.value = false
  from.value = ''
  wallet.value = null
  view.value = 'body'
  hovered.value = ''
  hoverTip.value = null
  meterTip.value = ''
  pickedGrade.value = ''
  if (noticeTimer !== undefined) {
    clearTimeout(noticeTimer)
    noticeTimer = undefined
  }
  release?.()
  release = undefined
}

/**
 * Escape's meaning, per state, the way the game's own is: an offer on the
 * patient's screen cancelled, as a popup's Escape is; out of an opened system
 * back to the body; then out of the chair (or away from the desk); an
 * invitation declined.
 */
function leave(): void {
  if (!open.value) return
  if (offer.value !== null && mode.value === 'sitter') {
    answerOffer(false)
    return
  }
  if (mode.value !== 'invite' && view.value === 'system') {
    back()
    return
  }
  if (mode.value === 'sitter') emit('opx:ripperdoc:stand', {})
  else if (mode.value === 'desk') emit('opx:ripperdoc:close', {})
  else if (mode.value === 'invite') answerInvite(false)
}

/** Back from an opened system to the whole body. */
function back(): void {
  view.value = 'body'
  hovered.value = ''
}

function answerInvite(accept: boolean): void {
  emit('opx:ripperdoc:answer', { what: 'invite', accept })
}

function answerOffer(accept: boolean): void {
  if (offer.value === null) return
  emit('opx:ripperdoc:answer', { what: 'offer', accept, offer: offer.value.id })
}

/** A system opened as the inventory tab: its pieces come back from the seam. */
function openTab(id: string): void {
  hoverTip.value = null
  view.value = 'system'
  if (id !== system.value) emit('opx:ripperdoc:browse', { system: id })
}

/** A filled slot opens its system with that piece shown. */
function openSlot(systemId: string, slot: Slot | null): void {
  if (slot === null) {
    openTab(systemId)
    return
  }
  hoverTip.value = null
  view.value = 'system'
  browsePiece(slot.id)
}

/** The filter's arrows: the previous or next system, round the ten. */
function step(delta: number): void {
  const count = systems.value.length
  if (count === 0) return
  const index = openIndex.value < 0 ? 0 : openIndex.value
  const next = systems.value[(index + delta + count) % count]
  if (next !== undefined) emit('opx:ripperdoc:browse', { system: next.id })
}

function browsePiece(id: string): void {
  if (detail.value === null || id !== detail.value.id) emit('opx:ripperdoc:browse', { piece: id })
}

/** A fit or an upgrade, a pull or a repair, named by piece -- the price is the server's. */
function propose(shown: Grade | null, kind: 'install' | 'remove' | 'repair'): void {
  if (!canAct.value || detail.value === null) return
  emit('opx:ripperdoc:offer', {
    entry: detail.value.id,
    grade: shown === null ? '' : shown.id,
    mode: kind
  })
}

function invite(player: Invitee): void {
  emit('opx:ripperdoc:invite', { player: player.id })
}

/** The tier a grid piece wears its colour in: the worn grade's, else its first. */
function tierOfPiece(row: Piece): number {
  return row.fitted !== '' ? row.tier : row.tierFrom
}

/**
 * A piece the patient's eddies cannot reach, not even its cheapest tier: the
 * grid marks it as the game's vendor grid does. Only the patient's own screen
 * knows the wallet; the desk's never marks one.
 */
function beyondWallet(row: Piece): boolean {
  return wallet.value !== null && row.fitted === '' && row.priceFrom > wallet.value
}

/** Where a small tooltip goes: beside the element, on the side away from the body. */
function tipAt(event: MouseEvent, side: 'left' | 'right'): { x: number; y: number } | null {
  const target = event.currentTarget as HTMLElement | null
  if (target === null) return null
  const box = target.getBoundingClientRect()
  return { x: side === 'left' ? box.left : box.right, y: box.top }
}

/** A slot on the body the pointer is on: what fills it, or that it is empty. */
function slotHover(group: Group, slot: Slot | null, event: MouseEvent): void {
  const at = tipAt(event, group.side)
  hovered.value = group.system.id
  if (at === null) return
  hoverTip.value = slot === null
    ? {
        title: t('ripperdoc.emptySlot'),
        tier: 0,
        iconic: false,
        equipped: false,
        lines: [t('ripperdoc.system.' + group.system.id), t('ripperdoc.pickSystem')],
        ...at,
        side: group.side
      }
    : {
        title: t(slot.name),
        tier: slot.tier,
        iconic: slot.iconic,
        equipped: true,
        lines: [
          t('ripperdoc.tier.' + slot.tier),
          slot.state === 'broken' ? t('ripperdoc.broken') : t('ripperdoc.condition', { points: slot.points })
        ],
        ...at,
        side: group.side
      }
}

/** A piece in the grid the pointer is on: its name, its tiers and its price. */
function pieceHover(row: Piece, event: MouseEvent): void {
  const at = tipAt(event, 'right')
  if (at === null) return
  const lines = [tiersOf(row), t('ripperdoc.kind.' + row.kind)]
  if (row.fitted !== '') lines.push(row.broken ? t('ripperdoc.broken') : t('ripperdoc.condition', { points: row.points }))
  else lines.push(t('ripperdoc.from', { price: money(row.priceFrom) }))
  hoverTip.value = {
    title: t(row.name),
    tier: tierOfPiece(row),
    iconic: row.iconic,
    equipped: row.fitted !== '',
    lines,
    ...at,
    side: 'right'
  }
}

function tipLeave(): void {
  hoverTip.value = null
}

/** The small tooltip's place on the screen, beside what it describes. */
const tipStyle = computed<Record<string, string>>((): Record<string, string> => {
  const tip = hoverTip.value
  if (tip === null) return {}
  return tip.side === 'left'
    ? { right: `calc(100vw - ${tip.x}px + 14px)`, top: `${tip.y}px` }
    : { left: `${tip.x + 14}px`, top: `${tip.y}px` }
})

// A new piece opened shows its own default tier.
watch(
  () => detail.value?.id ?? '',
  () => {
    pickedGrade.value = ''
  }
)

// A small tooltip never outlives what it describes: another system, the body
// again, or an offer over the screen takes it down (the tile under the pointer
// may be gone without a `mouseleave`).
watch(
  () => [view.value, system.value, offer.value?.id ?? 0, mode.value],
  () => {
    hoverTip.value = null
  }
)

/* -- the channel ----------------------------------------------------------- */

useBridge('opx:ripperdoc:view', (payload: Payload) => {
  guard(
    'ripperdoc:view',
    () => {
      const kind = text(payload.mode)

      if (kind === 'escape') {
        // The platform's Escape (`open77:pauseKey`), handed on by the clinic's
        // Lua: the page never sees the key itself while it only holds the cursor.
        leave()
        return
      }

      if (kind === 'notice') {
        // A transient line, no panel and no focus: the world keeps turning.
        flash.value = flashOf(payload)
        if (noticeTimer !== undefined) clearTimeout(noticeTimer)
        noticeTimer = setTimeout(() => {
          flash.value = null
          noticeTimer = undefined
        }, 4000)
        return
      }

      if (kind === 'sitter' || kind === 'desk' || kind === 'invite') {
        const seen = table(payload.offer)
        const offerId = num(seen.id)
        const capacity = table(payload.capacity)
        const armor = table(payload.armor)
        mode.value = kind
        chairName.value = text(payload.name)
        attended.value = payload.attended === true
        busy.value = payload.busy === true
        ready.value = payload.ready === true
        patientName.value = text(payload.patientName)
        seated.value = kind === 'desk' ? payload.seated === true : kind === 'sitter'
        from.value = text(payload.from)
        wallet.value = kind === 'sitter' ? num(payload.wallet) : null
        capacityUsed.value = num(capacity.used)
        capacityMax.value = num(capacity.max)
        capacityEnforced.value = capacity.enforced !== false
        armorNow.value = Math.max(0, num(armor.now))
        armorMax.value = Math.max(0, num(armor.max))
        family.value = text(payload.family) === 'male' ? 'male' : 'female'
        systems.value = list<Payload>(payload.systems)
          .slice(0, MAX_SYSTEMS)
          .map((row) => ({
            id: text(row.id),
            used: num(row.used),
            slots: num(row.slots),
            worn: slotsOf(row.worn)
          }))
          .filter((row) => row.id !== '')
        system.value = text(payload.system)
        pieces.value = list<Payload>(payload.pieces)
          .slice(0, MAX_PIECES)
          .map((row) => ({
            id: text(row.id),
            name: text(row.name, text(row.id)),
            kind: text(row.kind),
            icon: iconOf(row.icon),
            iconic: row.iconic === true,
            tierFrom: tierOf(row.tierFrom),
            tierTo: tierOf(num(row.tierTo, num(row.tierFrom, 1))),
            priceFrom: num(row.priceFrom),
            fitted: text(row.fitted),
            tier: tierOf(num(row.tier, num(row.tierFrom, 1))),
            points: clampPoints(row.points),
            state: text(row.state),
            broken: row.broken === true
          }))
          .filter((row) => row.id !== '')
        detail.value = detailOf(payload.detail)
        invitees.value = list<Payload>(payload.invitees)
          .slice(0, MAX_INVITEES)
          .map((row) => ({ id: num(row.id), name: text(row.name) }))
          .filter((row) => row.id !== 0)
        inviteOut.value = text(table(payload.invite).name)
        offer.value =
          offerId > 0
            ? {
                id: offerId,
                mode: text(seen.mode),
                entry: text(seen.entry),
                grade: text(seen.grade),
                name: text(seen.name),
                gradeName: text(seen.gradeName),
                price: num(seen.price),
                by: text(seen.by),
                icon: iconOf(seen.icon),
                tier: tierOf(seen.tier),
                iconic: seen.iconic === true
              }
            : null
        flash.value = flashOf(payload)

        if (!open.value) {
          open.value = true
          view.value = 'body'
          release?.()
          release = acquireFocus({
            id: 'ripperdoc.panel',
            onEscape: () => leave()
          })
        }
        return
      }

      // `closed` and anything this does not know: the reason is Lua's and it
      // has already said it. This page only takes the panel down.
      blank()
    },
    undefined
  )
})

onUnmounted(() => {
  if (noticeTimer !== undefined) clearTimeout(noticeTimer)
  release?.()
})
</script>

<template>
  <div class="rd" :class="{ open: open || flash !== null }">
    <!-- A notice is a line and nothing else: no screen behind it. -->
    <div v-if="flash !== null && !open" class="rd-warn rd-warn-top">
      <span class="rd-warn-text">{{ flashText(flash) }}</span>
    </div>

    <div v-if="open" class="rd-screen" :class="['is-' + view, 'is-' + family]">
      <div class="rd-stage">
        <!-- THE HEADER: the menu's name, the clinic, and who works the chair. -->
        <header class="rd-head">
          <div class="rd-title">{{ t('ripperdoc.title') }}</div>
          <div class="rd-sub">
            <span>{{ t('ripperdoc.chair', { name: t(chairName) }) }}</span>
            <span class="rd-sub-dot"></span>
            <span v-if="mode === 'desk'">{{ seated ? t('ripperdoc.patient', { name: patientName }) : t('ripperdoc.vacant') }}</span>
            <span v-else-if="mode === 'invite'">{{ t('ripperdoc.invite', { from }) }}</span>
            <span v-else>{{ attended ? t('ripperdoc.attended') : t('ripperdoc.self') }}</span>
          </div>
        </header>

        <!-- THE PLAYER'S EDDIES, top right, the game's cash symbol before them. -->
        <div v-if="wallet !== null" class="rd-money">
          <span class="rd-eddies" aria-hidden="true"></span>
          <span class="rd-money-value">{{ money(wallet) }}</span>
        </div>

        <template v-if="showsBody">
          <!-- CAPACITY: the left meter, on the game's own background. -->
          <div
            class="rd-meter rd-cap"
            @mouseenter="meterTip = 'capacity'"
            @mouseleave="meterTip = ''"
          >
            <img class="rd-meter-art" :src="artSrc('cap_bg')" alt="" draggable="false" />
            <span class="rd-meter-icon rd-cap-icon" aria-hidden="true"></span>
            <div class="rd-meter-max rd-cap-max">
              <span>{{ capacityMax }}</span>
            </div>
            <i
              v-for="(bar, index) in capacityBars"
              :key="'c' + index"
              class="rd-bar rd-cap-bar"
              :class="bar.state"
              :style="{ top: `calc(${bar.top} * var(--u))` }"
            ></i>
            <div class="rd-meter-now rd-cap-now" :class="{ 'is-full': capacityFull }" :style="{ top: `calc(${capacityLabels.now} * var(--u))` }">
              <span>{{ capacityUsed }}</span>
            </div>
            <div
              v-if="preview.capacity !== 0"
              class="rd-meter-cost rd-cap-cost"
              :class="{ 'is-over': capacityEnforced && capacityUsed + preview.capacity > capacityMax }"
              :style="{ top: `calc(${capacityLabels.cost} * var(--u))` }"
            >
              <span>{{ preview.capacity > 0 ? '+' : '' }}{{ preview.capacity }}</span>
            </div>
          </div>

          <!-- ARMOR: the right meter, the plating this chrome adds. -->
          <div
            class="rd-meter rd-armor"
            @mouseenter="meterTip = 'armor'"
            @mouseleave="meterTip = ''"
          >
            <img class="rd-meter-art" :src="artSrc('armor_bg')" alt="" draggable="false" />
            <span class="rd-meter-icon rd-armor-icon" aria-hidden="true"></span>
            <div class="rd-meter-max rd-armor-max">
              <span>{{ armorMax }}</span>
            </div>
            <i
              v-for="(bar, index) in armorBars"
              :key="'a' + index"
              class="rd-bar rd-armor-bar"
              :class="bar.state"
              :style="{ top: `calc(${bar.top} * var(--u))` }"
            ></i>
            <div class="rd-meter-now rd-armor-now" :style="{ top: `calc(${armorLabels.now} * var(--u))` }">
              <span>{{ armorNow }}</span>
            </div>
            <div v-if="preview.armor !== 0" class="rd-meter-cost rd-armor-cost" :style="{ top: `calc(${armorLabels.cost} * var(--u))` }">
              <span>{{ preview.armor > 0 ? '+' : '' }}{{ preview.armor }}</span>
            </div>
          </div>

          <!-- A METER'S TOOLTIP: what it measures, in the game's tooltip. -->
          <div v-if="meterTip !== ''" class="rd-tip rd-meter-tip" :class="'is-' + meterTip">
            <span class="rd-tip-strip"></span><span class="rd-tip-bg"></span><span class="rd-tip-fg"></span><span class="rd-tip-edge"></span>
            <div class="rd-tip-name">{{ meterTip === 'capacity' ? t('ripperdoc.capacityTitle') : t('ripperdoc.armorTitle') }}</div>
            <div class="rd-tip-rule"></div>
            <div class="rd-tip-copy">
              {{ meterTip === 'capacity' ? t('ripperdoc.capacityText') : t('ripperdoc.armorText', { max: armorMax }) }}
            </div>
            <div class="rd-tip-figure">
              {{ meterTip === 'capacity' ? t('ripperdoc.capacity', { used: capacityUsed, max: capacityMax }) : `${armorNow} / ${armorMax}` }}
            </div>
          </div>

          <!-- THE BODY: the paperdoll, and every system around it. -->
          <template v-if="view === 'body'">
            <div class="rd-doll" aria-hidden="true">
              <img
                class="rd-body rd-body-base"
                :class="{ dim: litLayer !== null, gone: litIsFull }"
                :src="artSrc(doll.base.file)"
                :style="layerStyle(doll.base)"
                alt=""
                draggable="false"
              />
              <img
                v-for="(layer, id) in doll.systems"
                :key="id"
                class="rd-body rd-body-lit"
                :class="{ on: hovered === id }"
                :src="artSrc(layer.file)"
                :style="layerStyle(layer)"
                alt=""
                draggable="false"
              />
            </div>

            <section
              v-for="group in groups"
              :key="group.system.id"
              class="rd-group"
              :class="['is-' + group.side, { 'is-lit': hovered === group.system.id }]"
              :style="group.style"
              @mouseenter="hovered = group.system.id"
              @mouseleave="hovered = ''"
            >
              <button type="button" class="rd-group-label" @click="openTab(group.system.id)">
                {{ t('ripperdoc.system.' + group.system.id) }}
              </button>
              <div class="rd-group-cells">
                <button
                  v-for="(cell, index) in group.cells"
                  :key="index"
                  type="button"
                  class="rd-tile"
                  :class="cell === null ? 'is-empty' : [tierClass(cell.tier, cell.iconic), 'is-equipped', { 'is-broken': cell.state === 'broken' }]"
                  @click="openSlot(group.system.id, cell)"
                  @mouseenter="slotHover(group, cell, $event)"
                  @mouseleave="tipLeave()"
                >
                  <span class="rd-tile-side"></span>
                  <span class="rd-tile-bg"></span>
                  <span class="rd-tile-lines"></span>
                  <span v-if="cell !== null && cell.iconic" class="rd-tile-iconic"></span>
                  <span class="rd-tile-frame"></span>
                  <span v-if="cell === null" class="rd-tile-add"></span>
                  <img
                    v-else-if="hasIcon(cell.icon)"
                    class="rd-tile-icon"
                    :src="iconSrc(cell.icon)"
                    alt=""
                    draggable="false"
                    @error="iconFailed(cell.icon)"
                  />
                  <span v-if="cell !== null" class="rd-tile-eq"></span>
                  <span v-if="cell !== null" class="rd-tile-cond" :class="conditionClass(cell.state, cell.points)">
                    <i :style="{ width: cell.points + '%' }"></i>
                  </span>
                </button>
              </div>
            </section>
          </template>

          <!-- ONE SYSTEM OPENED: the widget's inventory tab. -->
          <template v-else>
            <img
              v-if="zoomLayer !== null"
              class="rd-zoom"
              :src="artSrc(zoomLayer.file)"
              :style="zoomStyle"
              alt=""
              draggable="false"
            />

            <div class="rd-tab">
              <!-- THE FILTER: the system's name between two arrows, a dot per system. -->
              <div class="rd-filter">
                <span class="rd-filter-bg"></span>
                <button type="button" class="rd-filter-arrow is-left" @click="step(-1)"><span></span></button>
                <div class="rd-filter-name">{{ system ? t('ripperdoc.system.' + system) : '' }}</div>
                <button type="button" class="rd-filter-arrow is-right" @click="step(1)"><span></span></button>
                <div class="rd-dots">
                  <i v-for="(row, index) in systems" :key="row.id" :class="{ on: index === openIndex }"></i>
                </div>
              </div>

              <!-- THE SYSTEM'S SLOTS, what it wears now. -->
              <div v-if="openSystem !== null" class="rd-tab-slots">
                <div class="rd-tab-label">
                  {{ t('ripperdoc.installed') }}
                  <span class="rd-tab-count">{{ t('ripperdoc.slots', { used: openSystem.used, slots: openSystem.slots }) }}</span>
                </div>
                <div class="rd-group-cells">
                  <button
                    v-for="(cell, index) in openCells"
                    :key="index"
                    type="button"
                    class="rd-tile"
                    :class="cell === null ? 'is-empty' : [tierClass(cell.tier, cell.iconic), 'is-equipped', { 'is-broken': cell.state === 'broken', 'is-selected': detail !== null && detail.id === cell.id }]"
                    :disabled="cell === null"
                    @click="cell !== null && browsePiece(cell.id)"
                  >
                    <span class="rd-tile-side"></span>
                    <span class="rd-tile-bg"></span>
                    <span class="rd-tile-lines"></span>
                    <span v-if="cell !== null && cell.iconic" class="rd-tile-iconic"></span>
                    <span class="rd-tile-frame"></span>
                    <span v-if="cell === null" class="rd-tile-add"></span>
                    <img
                      v-else-if="hasIcon(cell.icon)"
                      class="rd-tile-icon"
                      :src="iconSrc(cell.icon)"
                      alt=""
                      draggable="false"
                      @error="iconFailed(cell.icon)"
                    />
                    <span v-if="cell !== null" class="rd-tile-eq"></span>
                    <span v-if="cell !== null" class="rd-tile-cond" :class="conditionClass(cell.state, cell.points)">
                      <i :style="{ width: cell.points + '%' }"></i>
                    </span>
                  </button>
                </div>
              </div>

              <div class="rd-divider"></div>

              <!-- THE GRID: every piece this clinic carries for the system. -->
              <div class="rd-grid">
                <div v-if="pieces.length === 0" class="rd-grid-empty">{{ t('ripperdoc.gridEmpty') }}</div>
                <button
                  v-for="row in pieces"
                  :key="row.id"
                  type="button"
                  class="rd-tile rd-item"
                  :class="[
                    tierClass(tierOfPiece(row), row.iconic),
                    {
                      'is-equipped': row.fitted !== '',
                      'is-selected': detail !== null && detail.id === row.id,
                      'is-broken': row.broken,
                      'is-poor': beyondWallet(row)
                    }
                  ]"
                  @click="browsePiece(row.id)"
                  @mouseenter="pieceHover(row, $event)"
                  @mouseleave="tipLeave()"
                >
                  <span class="rd-tile-side"></span>
                  <span class="rd-tile-bg"></span>
                  <span class="rd-tile-lines"></span>
                  <span v-if="row.iconic" class="rd-tile-iconic"></span>
                  <span class="rd-tile-frame"></span>
                  <img
                    v-if="hasIcon(row.icon)"
                    class="rd-tile-icon"
                    :src="iconSrc(row.icon)"
                    alt=""
                    draggable="false"
                    @error="iconFailed(row.icon)"
                  />
                  <span v-if="beyondWallet(row)" class="rd-tile-req"><i></i></span>
                  <span v-if="row.fitted !== ''" class="rd-tile-eq"></span>
                  <span v-if="row.fitted !== ''" class="rd-tile-cond" :class="conditionClass(row.broken ? 'broken' : row.state, row.points)">
                    <i :style="{ width: row.points + '%' }"></i>
                  </span>
                </button>
              </div>
            </div>

            <!-- THE PIECE: the game's item tooltip, docked, with the chair's controls. -->
            <article
              v-if="detail !== null && grade !== null"
              class="rd-tip rd-card"
              :class="[tierClass(grade.tier, detail.iconic), { 'is-equipped': shownInstalled }]"
            >
              <span class="rd-tip-strip"></span><span class="rd-tip-bg"></span><span class="rd-tip-fg"></span><span class="rd-tip-edge"></span>
              <span v-if="detail.iconic" class="rd-card-iconic"></span>
              <!-- The game's `itemEquipped` tab over the tooltip, for the tier the patient wears. -->
              <div v-if="shownInstalled" class="rd-tip-tab" :class="{ 'is-broken': detail.fitted?.broken === true }">
                <span class="rd-tip-tab-bg"></span><span class="rd-tip-tab-fg"></span>
                <span class="rd-tip-tab-text">{{ detail.fitted?.broken ? t('ripperdoc.broken') : t('ripperdoc.installed') }}</span>
              </div>
              <div class="rd-tip-name rd-card-name">{{ t(detail.name) }}</div>
              <div class="rd-tip-rule"></div>
              <div class="rd-card-rarity">
                <span>{{ t('ripperdoc.tier.' + grade.tier) }}</span>
                <span v-if="detail.iconic" class="rd-card-iconic-tag">{{ t('ripperdoc.iconic') }}</span>
              </div>
              <div class="rd-card-type">
                {{ t('ripperdoc.system.' + detail.system) }} · {{ t('ripperdoc.kind.' + detail.kind) }}
                <template v-if="detail.power !== ''"> · {{ t('ripperdoc.power.' + detail.power) }}</template>
              </div>
              <div v-if="grade.game !== ''" class="rd-card-game">{{ grade.game }}</div>

              <div class="rd-card-top">
                <div class="rd-card-cap">
                  <span class="rd-card-cap-value">{{ grade.capacity }}</span>
                  <span class="rd-cap-glyph" aria-hidden="true"></span>
                  <span class="rd-card-cap-label">{{ t('ripperdoc.capacityCost') }}</span>
                </div>
                <figure v-if="hasIcon(detail.icon)" class="rd-card-pic">
                  <img :src="iconSrc(detail.icon)" alt="" draggable="false" @error="iconFailed(detail.icon)" />
                </figure>
              </div>

              <!-- WHAT THE TIER DOES HERE: the effects and the numbers. -->
              <div v-if="grade.effects.length > 0 || grade.stats.length > 0 || grade.hack !== ''" class="rd-card-stats">
                <div v-for="row in grade.effects" :key="'e' + row.key" class="rd-stat is-effect">{{ effectText(row) }}</div>
                <div v-if="grade.hack !== ''" class="rd-stat is-effect">{{ t('ripperdoc.hack.' + grade.hack) }}</div>
                <div v-for="row in grade.stats" :key="'s' + row.key" class="rd-stat">
                  <span class="rd-stat-value">{{ statValue(row) }}</span>
                  <span class="rd-stat-name">{{ t('ripperdoc.stat.' + row.key) }}</span>
                </div>
              </div>

              <div v-if="(detail.desc !== '' && has(detail.desc)) || detail.kind === 'rp' || detail.unsold" class="rd-card-desc">
                <div class="rd-tip-rule"></div>
                <p v-if="detail.desc !== '' && has(detail.desc)">{{ t(detail.desc) }}</p>
                <p v-if="detail.kind === 'rp'" class="is-info">{{ t('ripperdoc.rpNote') }}</p>
                <p v-if="detail.unsold" class="is-info">{{ t('ripperdoc.offShelf') }}</p>
              </div>

              <!-- WHAT THE PATIENT WEARS OF IT: its condition, and the bench. -->
              <div v-if="detail.fitted !== null" class="rd-card-wear">
                <div class="rd-tip-rule"></div>
                <div class="rd-wear-line">
                  <span class="rd-wear-label">{{ t('ripperdoc.condition', { points: detail.fitted.broken ? 0 : detail.fitted.points }) }}</span>
                  <span class="rd-wear-state">{{ t('ripperdoc.state.' + (detail.fitted.broken ? 'broken' : detail.fitted.state || 'optimal')) }}</span>
                  <span v-if="!detail.fitted.broken && detail.fitted.left !== null" class="rd-wear-left">{{ leftText(detail.fitted.left) }}</span>
                </div>
                <div class="rd-wear-bar" :class="conditionClass(detail.fitted.broken ? 'broken' : detail.fitted.state, detail.fitted.points)">
                  <i :style="{ width: detail.fitted.points + '%' }"></i>
                </div>
                <div v-if="!detail.fitted.broken && detail.fitted.left !== null && detail.fitted.wearCap > 0" class="rd-wear-note">
                  {{ t('ripperdoc.hardUse', { used: hoursText(detail.fitted.wear), cap: hoursText(detail.fitted.wearCap) }) }}
                </div>
                <div v-if="!detail.fitted.inBody" class="rd-wear-note is-hot">{{ t('ripperdoc.outOfBody') }}</div>
                <div v-if="operating || selfService" class="rd-card-bench">
                  <button
                    type="button"
                    class="rd-btn is-small"
                    :disabled="!canAct || blockedByRecord(detail.kind) || (!detail.fitted.broken && detail.fitted.points >= 100)"
                    @click="propose(null, 'repair')"
                  >
                    <span class="rd-btn-bg"></span><span class="rd-btn-fg"></span>
                    <span class="rd-btn-text">{{ detail.fitted.inBody ? t('ripperdoc.act.repair') : t('ripperdoc.act.refit') }}</span>
                    <span class="rd-btn-price"><i class="rd-eddies-sm"></i>{{ money(detail.fitted.repair) }}</span>
                  </button>
                  <button
                    v-if="detail.fitted.inBody"
                    type="button"
                    class="rd-btn is-small is-quiet"
                    :disabled="!canAct || blockedByRecord(detail.kind)"
                    @click="propose(null, 'remove')"
                  >
                    <span class="rd-btn-bg"></span><span class="rd-btn-fg"></span>
                    <span class="rd-btn-text">{{ t('ripperdoc.act.remove') }}</span>
                    <span class="rd-btn-price"><i class="rd-eddies-sm"></i>{{ money(detail.remove) }}</span>
                  </button>
                </div>
              </div>

              <!-- THE TIERS, when the clinic has more than one: a chip each, in its rarity's colour. -->
              <template v-if="detail.grades.length > 1">
                <div class="rd-tip-rule"></div>
                <div class="rd-tiers">
                  <span class="rd-tiers-label">{{ t('ripperdoc.tierPick') }}</span>
                  <button
                    v-for="row in detail.grades"
                    :key="row.id"
                    type="button"
                    class="rd-tier-chip"
                    :class="[tierClass(row.tier), { 'is-picked': row.id === grade.id, 'is-owned': row.owned }]"
                    :title="t(row.name)"
                    @click="pickedGrade = row.id"
                  >
                    <span>{{ row.tier }}</span>
                  </button>
                </div>
              </template>

              <div v-if="primary !== null && primary.price !== null && (operating || selfService)" class="rd-card-buy">
                <button
                  type="button"
                  class="rd-btn"
                  :class="{ 'is-done': primary.price === null }"
                  :disabled="!primary.live"
                  @click="propose(grade, 'install')"
                >
                  <span class="rd-btn-bg"></span><span class="rd-btn-fg"></span>
                  <span class="rd-btn-text">{{ busy ? t('ripperdoc.working') : primary.label }}</span>
                  <span v-if="primary.price !== null" class="rd-btn-price"><i class="rd-eddies-sm"></i>{{ money(primary.price) }}</span>
                </button>
              </div>
              <div v-else-if="mode === 'sitter' && attended" class="rd-card-note">{{ t('ripperdoc.lockedAttended') }}</div>

              <!-- THE PRICE, as the tooltip's bottom row writes it. -->
              <div class="rd-card-bottom">
                <i class="rd-eddies-sm"></i>
                <span>{{ money(grade.price) }}</span>
              </div>
            </article>
          </template>
        </template>

        <!-- THE POPUPS, in the form of the game's own ripperdoc purchase popup
             (`purchase_popup`): the question in Red over a hairline, what it is
             about, and the answers under it, right-aligned. -->

        <!-- THE OPTION TO SIT: an invitation, answered. -->
        <div v-if="mode === 'invite'" class="rd-modal">
          <div class="rd-pop">
            <div class="rd-pop-title">{{ t('ripperdoc.invite', { from }) }}</div>
            <div class="rd-pop-rule"></div>
            <div class="rd-pop-line">{{ t('ripperdoc.chair', { name: t(chairName) }) }}</div>
            <div class="rd-pop-actions">
              <button type="button" class="rd-pbtn" @click="answerInvite(true)">
                <span class="rd-pbtn-bg"></span><span class="rd-pbtn-fg"></span>
                <span class="rd-pbtn-text">{{ t('ripperdoc.accept') }}</span>
              </button>
              <button type="button" class="rd-pbtn" @click="answerInvite(false)">
                <span class="rd-pbtn-bg"></span><span class="rd-pbtn-fg"></span>
                <span class="rd-pbtn-text">{{ t('ripperdoc.decline') }}</span>
              </button>
            </div>
          </div>
        </div>

        <!-- THE DESK WITH NOBODY IN THE CHAIR: offer the seat. -->
        <div v-else-if="mode === 'desk' && !seated" class="rd-modal">
          <div class="rd-pop">
            <div class="rd-pop-title">{{ t('ripperdoc.vacant') }}</div>
            <div class="rd-pop-rule"></div>
            <div class="rd-pop-head">{{ t('ripperdoc.invitees') }}</div>
            <div v-if="inviteOut !== ''" class="rd-pop-line is-hot">{{ t('ripperdoc.inviteOut', { name: inviteOut }) }}</div>
            <div v-if="invitees.length === 0" class="rd-pop-line is-faint">{{ t('ripperdoc.noInvitees') }}</div>
            <div v-for="row in invitees" :key="row.id" class="rd-invitee">
              <span class="rd-invitee-name">{{ row.name }}</span>
              <button type="button" class="rd-pbtn is-small" :disabled="inviteOut !== ''" @click="invite(row)">
                <span class="rd-pbtn-bg"></span><span class="rd-pbtn-fg"></span>
                <span class="rd-pbtn-text">{{ t('ripperdoc.offerSeat') }}</span>
              </button>
            </div>
          </div>
        </div>

        <!-- THE ONE OFFER AT A TIME: the purchase popup. Only the patient answers it. -->
        <div v-if="offer !== null && showsBody" class="rd-modal">
          <div class="rd-pop">
            <div class="rd-pop-title">{{ offerAsk(offer) }}</div>
            <div class="rd-pop-rule"></div>
            <!-- The item: its rarity band, its ground and frame, its picture, its name and its price. -->
            <div class="rd-buy-item" :class="tierClass(offer.tier, offer.iconic)">
              <span class="rd-buy-side"></span><span class="rd-buy-bg"></span><span class="rd-buy-fg"></span>
              <span v-if="offer.iconic" class="rd-buy-iconic"></span>
              <img
                v-if="hasIcon(offer.icon)"
                class="rd-buy-icon"
                :src="iconSrc(offer.icon)"
                alt=""
                draggable="false"
                @error="iconFailed(offer.icon)"
              />
              <div class="rd-buy-values">
                <div class="rd-buy-name">{{ t(offer.name) }}</div>
                <div v-if="offer.gradeName !== ''" class="rd-buy-tier">{{ t(offer.gradeName) }}</div>
                <div class="rd-buy-price"><i class="rd-eddies-sm"></i><span>{{ money(offer.price) }}</span></div>
              </div>
            </div>
            <div v-if="offer.by !== ''" class="rd-pop-head">{{ t('ripperdoc.offerBy', { name: offer.by }) }}</div>
            <div v-if="mode === 'sitter'" class="rd-pop-actions">
              <button type="button" class="rd-pbtn" @click="answerOffer(true)">
                <span class="rd-pbtn-bg"></span><span class="rd-pbtn-fg"></span>
                <span class="rd-pbtn-text">{{ t('ripperdoc.confirm') }}</span>
              </button>
              <button type="button" class="rd-pbtn" @click="answerOffer(false)">
                <span class="rd-pbtn-bg"></span><span class="rd-pbtn-fg"></span>
                <span class="rd-pbtn-text">{{ t('ripperdoc.cancel') }}</span>
              </button>
            </div>
            <div v-else class="rd-pop-line is-faint">{{ t('ripperdoc.waitPatient') }}</div>
          </div>
        </div>

        <!-- WHAT THE CHAIR HAS TO SAY: the game's warning box, in its blue. -->
        <div v-if="(!ready && showsBody) || flash !== null" class="rd-warn rd-warn-bottom">
          <span v-if="!ready && showsBody" class="rd-warn-text">{{ t('ripperdoc.notReadyBanner') }}</span>
          <span v-if="flash !== null" class="rd-warn-text">{{ flashText(flash) }}</span>
        </div>

        <!-- THE BUTTON HINT: what Escape does here. -->
        <footer v-if="mode !== 'invite'" class="rd-hints">
          <button type="button" class="rd-hint" @click="leave()">
            <span class="rd-key">ESC</span>
            <span>{{ view === 'system' && showsBody ? t('ripperdoc.back') : mode === 'desk' ? t('ripperdoc.stepAway') : t('ripperdoc.leave') }}</span>
          </button>
        </footer>
      </div>

      <!-- THE SMALL TOOLTIP of a slot or a piece the pointer is on, beside it. -->
      <div
        v-if="hoverTip !== null"
        class="rd-tip rd-hover-tip"
        :class="[hoverTip.tier > 0 ? tierClass(hoverTip.tier, hoverTip.iconic) : '', { 'is-equipped': hoverTip.equipped }]"
        :style="tipStyle"
      >
        <span class="rd-tip-strip"></span><span class="rd-tip-bg"></span><span class="rd-tip-fg"></span><span class="rd-tip-edge"></span>
        <div class="rd-tip-name">{{ hoverTip.title }}</div>
        <div class="rd-tip-rule"></div>
        <div v-for="(line, index) in hoverTip.lines" :key="index" class="rd-tip-copy" :class="{ 'is-rarity': index === 0 && hoverTip.tier > 0 }">
          {{ line }}
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* ── the base game's palette, read from its inkstyles (2.31) ─────────────────
   MainColors.* from base\gameplay\gui\common\main_colors.inkstyle; the tiers
   from rarity_menus.inkstyle; the tooltip's text from tooltip_style.inkstyle.
   The game writes a few of them above 1.0 (HDR): they are clamped here, and the
   "active" ones carry a glow instead. */
.rd {
  --rd-red: #ff6159; /* MainColors.Red */
  --rd-red-active: #ff7167; /* ActiveRed */
  --rd-red-mild: #ae3b36; /* MildRed */
  --rd-red-dark: #431618; /* DarkRed, PanelDarkRed, Tooltip.separatorLineColor */
  --rd-red-faint: #481d23; /* FaintRed, Tooltip.frameBG */
  --rd-red-sup: #df4a42; /* SupRed, Tooltip.textColor */
  --rd-red-price: #f7504a; /* the tooltip's price */
  --rd-blue: #5ef6ff; /* Blue */
  --rd-blue-active: #28ffff; /* ActiveBlue */
  --rd-blue-dark: #4db0a5; /* DarkBlue */
  --rd-blue-sup: #09777e; /* SupBlue */
  --rd-blue-mild: #349197; /* MildBlue */
  --rd-blue-faint: #172c2e; /* FaintBlue */
  --rd-yellow: #ffd741; /* Yellow */
  --rd-yellow-active: #ffff4e; /* ActiveYellow */
  --rd-green: #1ded83; /* Green */
  --rd-green-mild: #2e9c64; /* MildGreen */
  --rd-gold-dark: #d85912; /* DarkGold */
  --rd-combat-red: #ff3e34; /* CombatRed */
  --rd-grey: #a09a96; /* Grey */
  --rd-white: #ffffff;
  --rd-info: #cecece; /* TooltipText.cyberwareDescriptionInfoColor */
  --rd-stat-label: #4ca39a; /* TooltipStat.labelColor */
  --rd-bg-darkest: #0e0e17; /* Fullscreen_PrimaryBackgroundDarkest, Tooltip.backgroundColor */
  --rd-bg-dark: #121221; /* Fullscreen_PrimaryBackgroundDark */
  --rd-t1: #d6d0d0; /* Rarity.Common */
  --rd-t2: #1ded83; /* Rarity.Uncommon */
  --rd-t3: #2570d4; /* Rarity.Rare */
  --rd-t4: #9d2bf5; /* Rarity.Epic */
  --rd-t5: #fb932e; /* Rarity.Legendary */
  --rd-iconic: #f0b537; /* Rarity.Iconic */
  --rd-font: var(--op-font-display); /* Rajdhani: the game's raj.inkfontfamily */

  /* ONE UNIT PER PIXEL OF THE GAME'S 4K LAYOUT. The widget is authored at
     3840x2160 and scaled to the screen by its height; 16:9 is kept, centred. */
  --u: calc(min(100vh, 56.25vw) / 2160);

  position: fixed;
  inset: 0;
  font-family: var(--rd-font);
  font-weight: 500;
  color: var(--rd-red);
  opacity: 0;
  visibility: hidden;
  transition:
    opacity 0.18s ease-out,
    visibility 0.18s;
}

.rd.open {
  opacity: 1;
  visibility: visible;
}

/* The hub's dark ground over the world: Fullscreen_PrimaryBackgroundDarkest at
   the game's own 0.61, and darker to the edges. */
.rd-screen {
  position: absolute;
  inset: 0;
  background:
    radial-gradient(ellipse 60% 70% at 50% 48%, rgba(18, 18, 33, 0.72) 0%, rgba(14, 14, 23, 0.9) 70%, rgba(8, 8, 14, 0.97) 100%);
}

.rd-stage {
  position: absolute;
  left: calc(50% - 1920 * var(--u));
  top: calc(50% - 1080 * var(--u));
  width: calc(3840 * var(--u));
  height: calc(2160 * var(--u));
}

.rd button {
  font-family: inherit;
  color: inherit;
  background: none;
  border: 0;
  padding: 0;
  margin: 0;
  cursor: pointer;
}

.rd button:disabled {
  cursor: default;
}

/* ── the header ─────────────────────────────────────────────────────────── */

.rd-head {
  position: absolute;
  left: calc(130 * var(--u));
  top: calc(64 * var(--u));
}

.rd-title {
  font-size: calc(70 * var(--u));
  font-weight: 600;
  line-height: 1;
  letter-spacing: 0.02em;
  text-transform: uppercase;
  color: var(--rd-red);
}

.rd-sub {
  display: flex;
  align-items: center;
  gap: calc(18 * var(--u));
  margin-top: calc(16 * var(--u));
  font-size: calc(38 * var(--u));
  line-height: 1;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--rd-red-mild);
}

.rd-sub-dot {
  width: calc(9 * var(--u));
  height: calc(9 * var(--u));
  background: var(--rd-red-mild);
  transform: rotate(45deg);
}

/* THE EDDIES: the game's cash symbol in Yellow, the sum beside it. */
.rd-money {
  position: absolute;
  right: calc(130 * var(--u));
  top: calc(78 * var(--u));
  display: flex;
  align-items: center;
  gap: calc(20 * var(--u));
}

.rd-eddies {
  width: calc(75 * var(--u));
  height: calc(46 * var(--u));
  background: var(--rd-yellow);
  -webkit-mask: url('./art/eddies.png') center / contain no-repeat;
}

.rd-money-value {
  font-size: calc(56 * var(--u));
  font-weight: 600;
  line-height: 1;
  letter-spacing: 0.02em;
  color: var(--rd-red);
}

.rd-eddies-sm {
  display: inline-block;
  width: calc(44 * var(--u));
  height: calc(27 * var(--u));
  margin-right: calc(12 * var(--u));
  vertical-align: middle;
  background: var(--rd-yellow);
  -webkit-mask: url('./art/eddies.png') center / contain no-repeat;
}

/* ── the meters ─────────────────────────────────────────────────────────── */
/* Each is its background art at the widget's place (`capacity_bar` at 320,420,
   the art at -59,-18; `armor_bar` 490 from the right at 420, the art at -40,-17),
   with fifty bars over the art's own rows. */

.rd-meter {
  position: absolute;
  width: calc(245 * var(--u));
  height: calc(973 * var(--u));
}

.rd-cap {
  left: calc(261 * var(--u));
  top: calc(402 * var(--u));
}

.rd-armor {
  left: calc(3310 * var(--u));
  top: calc(403 * var(--u));
}

.rd-meter-art {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  opacity: 0.22;
  pointer-events: none;
}

.rd-bar {
  position: absolute;
  height: calc(10 * var(--u));
  color: transparent;
  pointer-events: none;
}

/* A capacity bar is the art's two halves (58-114 and 130-185). */
.rd-cap-bar {
  left: calc(58 * var(--u));
  width: calc(127 * var(--u));
}

.rd-cap-bar::before,
.rd-cap-bar::after {
  content: '';
  position: absolute;
  top: 0;
  bottom: 0;
  background: currentColor;
}

.rd-cap-bar::before {
  left: 0;
  width: calc(57 * var(--u));
}

.rd-cap-bar::after {
  left: calc(72 * var(--u));
  width: calc(55 * var(--u));
}

/* An armor bar is one run (77-162). */
.rd-armor-bar {
  left: calc(77 * var(--u));
  width: calc(86 * var(--u));
  background: currentColor;
}

/* The meters' states (ripperdoc_poor.inkstyle, NewMeter.*). */
.rd-bar.is-used {
  color: var(--rd-yellow);
  opacity: 0.7;
}
.rd-bar.is-add {
  color: var(--rd-green);
}
.rd-bar.is-remove {
  color: var(--rd-yellow-active);
}
.rd-bar.is-over {
  color: var(--rd-red);
}
.rd-bar.is-low {
  color: var(--rd-green-mild);
}
.rd-bar.is-mid {
  color: var(--rd-blue);
  opacity: 0.6;
}
.rd-bar.is-high {
  color: var(--rd-gold-dark);
}
.rd-armor-bar.is-remove {
  color: var(--rd-combat-red);
}

.rd-meter-icon {
  position: absolute;
  top: calc(-150 * var(--u));
  width: calc(64 * var(--u));
  height: calc(64 * var(--u));
}

.rd-cap-icon {
  left: calc(90 * var(--u));
  background: var(--rd-yellow);
  -webkit-mask: url('./art/cap_icon.png') center / contain no-repeat;
}

.rd-armor-icon {
  left: calc(88 * var(--u));
  background: var(--rd-blue);
  -webkit-mask: url('./art/armor_icon.png') center / contain no-repeat;
}

/* The labels: the game's counter label, filled for what is, stroked for the
   limit and for what the shown tier would change. */
.rd-meter-max,
.rd-meter-now,
.rd-meter-cost {
  position: absolute;
  display: flex;
  align-items: center;
  justify-content: center;
  min-width: calc(90 * var(--u));
  height: calc(50 * var(--u));
  padding: 0 calc(14 * var(--u));
  font-size: calc(50 * var(--u));
  line-height: 1;
  pointer-events: none;
}

.rd-meter-max::before,
.rd-meter-now::before,
.rd-meter-cost::before {
  content: '';
  position: absolute;
  inset: 0;
  background: currentColor;
  -webkit-mask-box-image: url('./art/count_line.png') 8 / calc(8 * var(--u));
}

.rd-meter-now::before {
  -webkit-mask-box-image: url('./art/count.png') 8 / calc(8 * var(--u));
}

.rd-meter-max span,
.rd-meter-now span,
.rd-meter-cost span {
  position: relative;
}

.rd-meter-max {
  top: calc(-66 * var(--u));
  left: calc(76 * var(--u));
}

.rd-cap-max {
  color: var(--rd-red);
}

.rd-cap-max::before {
  opacity: 0.4;
}

.rd-armor-max {
  left: calc(74 * var(--u));
  color: var(--rd-blue-sup);
}

.rd-armor-max::before {
  opacity: 0.4;
}

/* What is: black on the meter's colour, at the top of the fill. */
.rd-meter-now {
  font-weight: 600;
  transition: top 0.3s ease-out;
}

.rd-meter-now span {
  color: #000000;
}

.rd-cap-now {
  left: calc(206 * var(--u));
  color: var(--rd-yellow);
}

.rd-cap-now.is-full {
  color: var(--rd-red);
}

.rd-armor-now {
  left: calc(-60 * var(--u));
  min-width: calc(120 * var(--u));
  color: var(--rd-blue);
}

.rd-meter-cost {
  transition: top 0.3s ease-out;
}

.rd-cap-cost {
  left: calc(206 * var(--u));
  color: var(--rd-green);
}

.rd-cap-cost.is-over {
  color: var(--rd-red-active);
}

.rd-armor-cost {
  left: calc(-60 * var(--u));
  min-width: calc(120 * var(--u));
  color: var(--rd-green);
}

/* ── tooltips: the game's unified tooltip ───────────────────────────────── */
/* `itemTooltip` (itemtooltip.inkwidget): the band down the left
   (`color_flip_bg`, Tooltip.frameBG), the ground (`unified_tooltip_fill`,
   Tooltip.backgroundColor) two units under it, its stroke
   (`unified_tooltip_stroke`, Tooltip.frameColor), and the outline around the
   whole (`unified_tooltip_outline`, Tooltip.frameEquippedColor). Red by
   default; Blue for what the patient wears (the tooltip's `Equipped` state). */

.rd-tip {
  --rd-tip-edge: var(--rd-red);
  --rd-tip-line: var(--rd-red-mild);
  --rd-tip-flip: var(--rd-red-faint);
  position: absolute;
  padding: calc(28 * var(--u)) calc(44 * var(--u)) calc(34 * var(--u)) calc(84 * var(--u));
  color: var(--rd-red-sup);
}

.rd-tip.is-equipped {
  --rd-tip-edge: var(--rd-blue);
  --rd-tip-line: var(--rd-blue-mild);
  --rd-tip-flip: var(--rd-blue-faint);
}

.rd-tip > * {
  position: relative;
}

.rd-tip > .rd-tip-strip,
.rd-tip > .rd-tip-bg,
.rd-tip > .rd-tip-fg,
.rd-tip > .rd-tip-edge {
  position: absolute;
  top: 0;
  right: 0;
  bottom: 0;
  pointer-events: none;
}

.rd-tip > .rd-tip-strip {
  left: 0;
  right: auto;
  width: calc(32 * var(--u));
  background: var(--rd-tip-flip);
  -webkit-mask-box-image: url('./art/flip_bg.png') 9 9 21 18 / calc(9 * var(--u)) calc(9 * var(--u)) calc(21 * var(--u)) calc(18 * var(--u));
}

.rd-tip > .rd-tip-bg {
  left: calc(30 * var(--u));
  background: var(--rd-bg-darkest);
  -webkit-mask-box-image: url('./art/tip_fill.png') 14 60 60 14 / calc(14 * var(--u)) calc(60 * var(--u)) calc(60 * var(--u)) calc(14 * var(--u));
}

.rd-tip > .rd-tip-fg {
  left: calc(32 * var(--u));
  background: var(--rd-tip-line);
  -webkit-mask-box-image: url('./art/tip_line.png') 14 60 60 14 / calc(14 * var(--u)) calc(60 * var(--u)) calc(60 * var(--u)) calc(14 * var(--u));
}

.rd-tip > .rd-tip-edge {
  left: 0;
  background: var(--rd-tip-edge);
  -webkit-mask-box-image: url('./art/tip_edge.png') 20 60 60 20 / calc(20 * var(--u)) calc(60 * var(--u)) calc(60 * var(--u)) calc(20 * var(--u));
}

/* The `itemEquipped` tab on top of an installed piece's tooltip: its own
   ground (`color_flip_bg_180`, the darkest at 0.7 over MildBlue at 0.5), its
   frame in Blue, the word in Blue. */
.rd-tip > .rd-tip-tab {
  position: absolute;
  left: 0;
  right: 0;
  bottom: calc(100% - 2 * var(--u));
  height: calc(56 * var(--u));
  display: flex;
  align-items: center;
  justify-content: center;
}

.rd-tip-tab-bg,
.rd-tip-tab-fg {
  position: absolute;
  inset: 0;
}

.rd-tip-tab-bg {
  background: #1a3f45;
  -webkit-mask-box-image: url('./art/tab_bg.png') 21 18 9 9 / calc(21 * var(--u)) calc(18 * var(--u)) calc(9 * var(--u)) calc(9 * var(--u));
}

.rd-tip-tab-fg {
  background: var(--rd-blue);
  -webkit-mask-box-image: url('./art/tab_fg.png') 21 18 9 9 / calc(21 * var(--u)) calc(18 * var(--u)) calc(9 * var(--u)) calc(9 * var(--u));
}

.rd-tip-tab-text {
  position: relative;
  padding-top: calc(4 * var(--u));
  font-size: calc(38 * var(--u));
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--rd-blue);
}

/* Worn but broken: the same tab in the game's reds. */
.rd-tip-tab.is-broken .rd-tip-tab-bg {
  background: var(--rd-red-dark);
}

.rd-tip-tab.is-broken .rd-tip-tab-fg {
  background: var(--rd-combat-red);
}

.rd-tip-tab.is-broken .rd-tip-tab-text {
  color: var(--rd-combat-red);
}

.rd-tip-name {
  font-size: calc(42 * var(--u));
  font-weight: 500;
  line-height: 1.15;
  letter-spacing: 0.03em;
  text-transform: uppercase;
  color: var(--rd-blue);
}

.rd-tip-rule {
  height: calc(2 * var(--u));
  margin: calc(18 * var(--u)) 0;
  background: var(--rd-red-dark);
}

.rd-tip-copy {
  font-size: calc(34 * var(--u));
  line-height: 1.3;
  color: var(--rd-info);
}

.rd-tip-figure {
  margin-top: calc(16 * var(--u));
  font-size: calc(38 * var(--u));
  font-weight: 600;
  letter-spacing: 0.03em;
  color: var(--rd-yellow);
}

/* The rarity colours: on the name, and on everything a tier writes. */
.is-t1 {
  --rd-rarity: var(--rd-t1);
}
.is-t2 {
  --rd-rarity: var(--rd-t2);
}
.is-t3 {
  --rd-rarity: var(--rd-t3);
}
.is-t4 {
  --rd-rarity: var(--rd-t4);
}
.is-t5 {
  --rd-rarity: var(--rd-t5);
}
.is-iconic {
  --rd-rarity: var(--rd-iconic);
}

/* The name stays Blue, as the header's `nameLabel` is; the rarity line under
   it takes the tier's colour (`Rarity.mainColor`), in capitals. */
.rd-tip .is-rarity {
  color: var(--rd-rarity);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

/* Over the slots it lies across, as a tooltip does. */
.rd-meter-tip {
  z-index: 3;
  width: calc(720 * var(--u));
  top: calc(420 * var(--u));
  pointer-events: none;
}

.rd-meter-tip.is-capacity {
  left: calc(620 * var(--u));
}

.rd-meter-tip.is-armor {
  left: calc(2500 * var(--u));
}

.rd-meter-tip.is-capacity .rd-tip-name {
  color: var(--rd-yellow);
}

.rd-hover-tip {
  position: fixed;
  z-index: 5;
  width: calc(620 * var(--u));
  pointer-events: none;
}

/* ── the paperdoll ──────────────────────────────────────────────────────── */

.rd-doll {
  position: absolute;
  inset: 0;
  pointer-events: none;
}

.rd-body {
  position: absolute;
  object-fit: contain;
  transition: opacity 0.18s ease-out;
}

.rd-body-base.dim {
  opacity: 0.5;
}

.rd-body-base.gone {
  opacity: 0;
}

.rd-body-lit {
  opacity: 0;
}

.rd-body-lit.on {
  opacity: 1;
  filter: drop-shadow(0 0 calc(18 * var(--u)) rgba(94, 246, 255, 0.25));
}

/* ── the systems around the body ────────────────────────────────────────── */

.rd-group {
  position: absolute;
}

.rd-group.is-left {
  text-align: right;
}

.rd-group-label {
  display: block;
  width: 100%;
  padding-bottom: calc(14 * var(--u)) !important;
  font-size: calc(50 * var(--u));
  line-height: 1;
  letter-spacing: 0.03em;
  text-transform: uppercase;
  text-align: inherit;
  white-space: nowrap;
  color: var(--rd-red) !important;
  transition:
    color 0.12s,
    text-shadow 0.12s;
}

.rd-group.is-lit .rd-group-label,
.rd-group-label:hover {
  color: var(--rd-red-active) !important;
  text-shadow: 0 0 calc(14 * var(--u)) rgba(255, 97, 89, 0.5);
}

.rd-group-cells {
  display: flex;
  gap: calc(10 * var(--u));
}

.rd-group.is-left .rd-group-cells {
  justify-content: flex-end;
}

/* ── a tile: the game's item display (`itemDisplay`, 216x194) ───────────── */
/* The rarity band on the left (`item_side_bg`), then the cell: its dark ground
   (`item_bg`), the circuit lines of an empty one (`texture_1slot`), the gold of
   an iconic one, and its frame (`item_fg`). */

.rd-tile {
  position: relative;
  flex: none;
  width: calc(216 * var(--u));
  height: calc(194 * var(--u));
}

.rd-tile > span,
.rd-tile > img {
  position: absolute;
  pointer-events: none;
}

.rd-tile-side {
  left: 0;
  top: 0;
  bottom: 0;
  width: calc(23 * var(--u));
  background: var(--rd-bg-darkest);
  opacity: 0.89;
  -webkit-mask-box-image: url('./art/item_side.png') 10 8 90 10 / calc(10 * var(--u)) calc(8 * var(--u)) calc(90 * var(--u)) calc(10 * var(--u));
}

.rd-tile[class*='is-t'] .rd-tile-side,
.rd-tile.is-iconic .rd-tile-side {
  background: var(--rd-rarity);
  opacity: 1;
}

.rd-tile-bg,
.rd-tile-lines,
.rd-tile-iconic,
.rd-tile-frame {
  left: calc(25 * var(--u));
  top: 0;
  right: 0;
  bottom: 0;
}

.rd-tile-bg {
  background: var(--rd-bg-darkest);
  opacity: 0.89;
  -webkit-mask-box-image: url('./art/item_bg.png') 23 75 75 23 / calc(23 * var(--u)) calc(75 * var(--u)) calc(75 * var(--u)) calc(23 * var(--u));
  transition: background 0.12s;
}

.rd-tile-lines {
  background: var(--rd-red);
  opacity: 0.05;
  -webkit-mask: url('./art/slot_lines.webp') center / 100% 100% no-repeat;
}

.rd-tile.is-empty .rd-tile-lines {
  opacity: 0.1;
}

/* ONE COPY OF THE ICONIC ART. The page carries its images inline (nothing is
   fetched by the surface), and a `url()` is inlined wherever it is written: the
   three rules that named this .webp each carried their own 23 kB copy of it. */
.rd-tile-iconic,
.rd-card-iconic,
.rd-buy-iconic {
  -webkit-mask-image: url('./art/iconic.webp');
  -webkit-mask-repeat: no-repeat;
}

.rd-tile-iconic {
  background: var(--rd-iconic);
  opacity: 0.3;
  -webkit-mask-position: center;
  -webkit-mask-size: 100% 100%;
}

.rd-tile-frame {
  background: var(--rd-red);
  opacity: 0.2;
  -webkit-mask-box-image: url('./art/item_fg.png') 23 75 75 23 / calc(23 * var(--u)) calc(75 * var(--u)) calc(75 * var(--u)) calc(23 * var(--u));
  transition:
    opacity 0.12s,
    background 0.12s;
}

.rd-tile.is-equipped .rd-tile-frame {
  background: var(--rd-blue);
  opacity: 0.3;
}

.rd-tile:not(:disabled):hover .rd-tile-bg {
  background: #2a1016;
}

.rd-tile:not(:disabled):hover .rd-tile-frame {
  background: var(--rd-red);
  opacity: 0.85;
}

.rd-tile.is-selected .rd-tile-frame,
.rd-tile.is-selected:hover .rd-tile-frame {
  background: var(--rd-blue-active);
  opacity: 0.85;
}

.rd-tile.is-broken .rd-tile-frame {
  background: var(--rd-combat-red);
  opacity: 0.6;
}

/* The empty slot's `+` (`icon_add`, Blue at the game's 0.25). */
.rd-tile-add {
  left: calc(25 * var(--u));
  right: 0;
  top: 0;
  bottom: 0;
  margin: auto;
  width: calc(46 * var(--u));
  height: calc(46 * var(--u));
  background: var(--rd-blue);
  opacity: 0.35;
  -webkit-mask: url('./art/add.png') center / contain no-repeat;
}

.rd-tile:not(:disabled):hover .rd-tile-add {
  opacity: 0.8;
}

.rd-tile-icon {
  left: calc(38 * var(--u));
  top: calc(18 * var(--u));
  width: calc(166 * var(--u));
  height: calc(140 * var(--u));
  object-fit: contain;
}

.rd-tile.is-broken .rd-tile-icon {
  opacity: 0.45;
  filter: grayscale(1);
}

/* Worn: the game's equipped corner (`equipped_accent`, Blue). */
.rd-tile-eq {
  right: calc(3 * var(--u));
  bottom: calc(3 * var(--u));
  width: calc(43 * var(--u));
  height: calc(41 * var(--u));
  background: var(--rd-blue);
  -webkit-mask: url('./art/eq_mark.png') center / contain no-repeat;
}

/* Its condition, on this server: a line along the cell's foot. */
.rd-tile-cond {
  left: calc(40 * var(--u));
  right: calc(56 * var(--u));
  bottom: calc(14 * var(--u));
  height: calc(6 * var(--u));
  background: rgba(255, 255, 255, 0.07);
}

.rd-tile-cond i,
.rd-wear-bar i {
  display: block;
  height: 100%;
  background: currentColor;
}

.is-whole {
  color: var(--rd-blue);
}
.is-worn {
  color: var(--rd-yellow);
}
.is-failing {
  color: var(--rd-red-active);
}
.is-broken {
  color: var(--rd-combat-red);
}

/* A piece beyond the wallet: the game's `UnavailableMoney` cell (the picture
   grey at 0.3, the ground at 0.4) with its `Money` requirement over it -- the
   red cash symbol in a label frame, centred (slots_style.inkstyle,
   `itemDisplay.requirementsWrapper`). */
.rd-tile.is-poor .rd-tile-bg {
  opacity: 0.4;
}

.rd-tile.is-poor .rd-tile-icon {
  opacity: 0.3;
  filter: grayscale(1);
}

.rd-tile-req {
  left: calc(25 * var(--u));
  right: 0;
  top: 0;
  bottom: 0;
  margin: auto;
  width: calc(160 * var(--u));
  height: calc(43 * var(--u));
}

.rd-tile-req::before,
.rd-tile-req::after {
  content: '';
  position: absolute;
  inset: calc(-5 * var(--u));
}

.rd-tile-req::before {
  background: var(--rd-bg-darkest);
  opacity: 0.9;
  -webkit-mask-box-image: url('./art/label.png') 13 30 13 30 / calc(13 * var(--u)) calc(30 * var(--u)) calc(13 * var(--u)) calc(30 * var(--u));
}

.rd-tile-req::after {
  background: var(--rd-red);
  -webkit-mask-box-image: url('./art/label_line.png') 13 30 13 30 / calc(13 * var(--u)) calc(30 * var(--u)) calc(13 * var(--u)) calc(30 * var(--u));
}

.rd-tile-req i {
  position: absolute;
  z-index: 1;
  inset: 0;
  margin: auto;
  width: calc(46 * var(--u));
  height: calc(28 * var(--u));
  background: var(--rd-red);
  -webkit-mask: url('./art/eddies.png') center / contain no-repeat;
}

/* ── one system opened: the inventory tab ───────────────────────────────── */

.rd-zoom {
  position: absolute;
  object-fit: contain;
  opacity: 0.95;
  pointer-events: none;
  filter: drop-shadow(0 0 calc(30 * var(--u)) rgba(94, 246, 255, 0.12));
}

.rd-tab {
  position: absolute;
  left: calc(800 * var(--u));
  top: calc(300 * var(--u));
  width: calc(906 * var(--u));
}

/* The filter: `cell_bg` / `cell_fg`, the name in Blue between two arrows. */
.rd-filter {
  position: relative;
  width: calc(888 * var(--u));
  height: calc(100 * var(--u));
}

.rd-filter-bg {
  position: absolute;
  inset: 0;
}

.rd-filter-bg::before,
.rd-filter-bg::after {
  content: '';
  position: absolute;
  inset: 0;
}

.rd-filter-bg::before {
  background: var(--rd-bg-dark);
  opacity: 0.6;
  -webkit-mask-box-image: url('./art/cell_bg.png') 20 30 30 20 / calc(20 * var(--u)) calc(30 * var(--u)) calc(30 * var(--u)) calc(20 * var(--u));
}

.rd-filter-bg::after {
  background: var(--rd-red);
  opacity: 0.3;
  -webkit-mask-box-image: url('./art/cell_fg.png') 20 30 30 20 / calc(20 * var(--u)) calc(30 * var(--u)) calc(30 * var(--u)) calc(20 * var(--u));
}

.rd-filter-name {
  position: absolute;
  left: calc(120 * var(--u));
  right: calc(120 * var(--u));
  top: calc(20 * var(--u));
  text-align: center;
  font-size: calc(42 * var(--u));
  line-height: 1;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  white-space: nowrap;
  color: var(--rd-blue);
}

.rd-filter-arrow {
  position: absolute !important;
  top: 0;
  bottom: 0;
  width: calc(110 * var(--u));
}

.rd-filter-arrow.is-left {
  left: 0;
}

.rd-filter-arrow.is-right {
  right: 0;
}

.rd-filter-arrow span {
  position: absolute;
  top: calc(34 * var(--u));
  width: calc(24 * var(--u));
  height: calc(24 * var(--u));
  border-top: calc(5 * var(--u)) solid var(--rd-red);
  border-left: calc(5 * var(--u)) solid var(--rd-red);
}

.rd-filter-arrow.is-left span {
  left: calc(46 * var(--u));
  transform: rotate(-45deg);
}

.rd-filter-arrow.is-right span {
  right: calc(46 * var(--u));
  transform: rotate(135deg);
}

.rd-filter-arrow:hover span {
  border-color: var(--rd-blue-active);
}

.rd-dots {
  position: absolute;
  left: 50%;
  bottom: calc(15 * var(--u));
  display: flex;
  gap: calc(8 * var(--u));
  width: calc(560 * var(--u));
  transform: translateX(-50%);
}

.rd-dots i {
  flex: 1;
  height: calc(8 * var(--u));
  background: var(--rd-red-dark);
}

.rd-dots i.on {
  background: var(--rd-blue);
}

.rd-tab-slots {
  margin-top: calc(26 * var(--u));
}

.rd-tab-label {
  display: flex;
  align-items: baseline;
  gap: calc(20 * var(--u));
  padding-bottom: calc(14 * var(--u));
  font-size: calc(42 * var(--u));
  line-height: 1;
  letter-spacing: 0.03em;
  text-transform: uppercase;
  color: var(--rd-red);
}

.rd-tab-count {
  font-size: calc(34 * var(--u));
  color: var(--rd-red-mild);
}

.rd-divider {
  height: calc(2 * var(--u));
  margin: calc(30 * var(--u)) calc(68 * var(--u)) calc(30 * var(--u)) 0;
  background: var(--rd-red);
}

.rd-grid {
  display: grid;
  grid-template-columns: repeat(4, calc(216 * var(--u)));
  gap: calc(12 * var(--u));
  max-height: calc(1030 * var(--u));
  overflow-y: auto;
  padding-right: calc(14 * var(--u));
}

/* The game's slider: a PanelDarkRed track, a Red handle at half. */
.rd-grid::-webkit-scrollbar {
  width: calc(8 * var(--u));
}

.rd-grid::-webkit-scrollbar-track {
  background: var(--rd-red-dark);
}

.rd-grid::-webkit-scrollbar-thumb {
  background: rgba(255, 97, 89, 0.5);
}

.rd-grid-empty {
  grid-column: 1 / -1;
  font-size: calc(38 * var(--u));
  color: var(--rd-red-mild);
}

/* ── the piece: the item tooltip, docked ────────────────────────────────── */

.rd-card {
  left: calc(1800 * var(--u));
  top: calc(300 * var(--u));
  width: calc(760 * var(--u));
}

.rd-card > .rd-card-iconic {
  left: calc(32 * var(--u));
}

/* The header's name: ReadableFontSize, Blue. */
.rd-card .rd-card-name {
  font-size: calc(50 * var(--u));
}

.rd-card-iconic {
  position: absolute !important;
  inset: 0;
  background: var(--rd-iconic);
  opacity: 0.12;
  -webkit-mask-position: right bottom;
  -webkit-mask-size: 60% auto;
  pointer-events: none;
}

.rd-card-rarity {
  display: flex;
  gap: calc(24 * var(--u));
  font-size: calc(34 * var(--u));
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--rd-rarity);
}

.rd-card-iconic-tag {
  color: var(--rd-iconic);
}

.rd-card-type {
  margin-top: calc(8 * var(--u));
  font-size: calc(30 * var(--u));
  letter-spacing: 0.02em;
  color: var(--rd-red);
}

.rd-card-game {
  margin-top: calc(6 * var(--u));
  font-size: calc(28 * var(--u));
  color: var(--rd-grey);
}

.rd-card-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: calc(20 * var(--u));
  margin-top: calc(22 * var(--u));
}

/* The capacity the tier takes: the game's big yellow figure and its icon. */
.rd-card-cap {
  display: flex;
  align-items: center;
  gap: calc(14 * var(--u));
  color: var(--rd-yellow);
}

.rd-card-cap-value {
  font-size: calc(70 * var(--u));
  line-height: 1;
}

.rd-cap-glyph {
  width: calc(44 * var(--u));
  height: calc(44 * var(--u));
  background: var(--rd-yellow);
  -webkit-mask: url('./art/cap_icon.png') center / contain no-repeat;
}

.rd-card-cap-label {
  font-size: calc(30 * var(--u));
  letter-spacing: 0.04em;
  color: var(--rd-yellow);
  opacity: 0.8;
}

.rd-card-pic {
  flex: none;
  width: calc(230 * var(--u));
  height: calc(150 * var(--u));
  margin: 0;
}

.rd-card-pic img {
  width: 100%;
  height: 100%;
  object-fit: contain;
}

.rd-card-stats {
  display: flex;
  flex-direction: column;
  gap: calc(8 * var(--u));
  margin-top: calc(22 * var(--u));
}

.rd-stat {
  display: flex;
  gap: calc(14 * var(--u));
  font-size: calc(36 * var(--u));
  line-height: 1.2;
  color: var(--rd-blue);
}

.rd-stat-name {
  color: var(--rd-stat-label);
  text-transform: uppercase;
}

.rd-card-desc p {
  display: -webkit-box;
  margin: 0 0 calc(12 * var(--u));
  overflow: hidden;
  font-size: calc(34 * var(--u));
  line-height: 1.3;
  color: var(--rd-white);
  opacity: 0.88;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 6;
}

.rd-card-desc p.is-info {
  color: var(--rd-info);
  opacity: 0.8;
}

.rd-wear-line {
  display: flex;
  align-items: baseline;
  flex-wrap: wrap;
  gap: calc(8 * var(--u)) calc(22 * var(--u));
  font-size: calc(32 * var(--u));
  text-transform: uppercase;
  letter-spacing: 0.03em;
}

.rd-wear-label {
  color: var(--rd-red);
}

.rd-wear-state {
  color: var(--rd-red-mild);
}

.rd-wear-left {
  margin-left: auto;
  color: var(--rd-info);
  white-space: nowrap;
}

.rd-wear-bar {
  height: calc(8 * var(--u));
  margin: calc(14 * var(--u)) 0 calc(10 * var(--u));
  background: rgba(255, 255, 255, 0.07);
}

.rd-wear-note {
  font-size: calc(28 * var(--u));
  line-height: 1.3;
  color: var(--rd-info);
  opacity: 0.8;
}

.rd-wear-note.is-hot {
  color: var(--rd-red-active);
  opacity: 1;
}

.rd-card-bench {
  display: flex;
  gap: calc(16 * var(--u));
  margin-top: calc(18 * var(--u));
}

.rd-card-bench .rd-btn {
  flex: 1;
}

/* The tiers, one chip each in the rarity's colour; the one shown framed. */
.rd-tiers {
  display: flex;
  align-items: center;
  gap: calc(12 * var(--u));
}

.rd-tiers-label {
  margin-right: calc(14 * var(--u));
  font-size: calc(32 * var(--u));
  letter-spacing: 0.03em;
  text-transform: uppercase;
  color: var(--rd-red);
}

.rd-tier-chip {
  position: relative;
  width: calc(76 * var(--u));
  height: calc(64 * var(--u));
  font-size: calc(36 * var(--u));
  font-weight: 600;
  color: var(--rd-rarity) !important;
}

.rd-tier-chip::before,
.rd-tier-chip::after {
  content: '';
  position: absolute;
  inset: 0;
}

.rd-tier-chip::before {
  background: var(--rd-rarity);
  opacity: 0.12;
  -webkit-mask-box-image: url('./art/cell_bg.png') 20 30 30 20 / calc(10 * var(--u)) calc(15 * var(--u)) calc(15 * var(--u)) calc(10 * var(--u));
}

.rd-tier-chip::after {
  background: var(--rd-rarity);
  opacity: 0.5;
  -webkit-mask-box-image: url('./art/cell_fg.png') 20 30 30 20 / calc(10 * var(--u)) calc(15 * var(--u)) calc(15 * var(--u)) calc(10 * var(--u));
}

.rd-tier-chip span {
  position: relative;
}

.rd-tier-chip:hover::after {
  opacity: 1;
}

.rd-tier-chip.is-picked::after {
  background: var(--rd-blue-active);
  opacity: 1;
}

.rd-tier-chip.is-owned::before {
  opacity: 0.35;
}

.rd-card-buy {
  margin-top: calc(22 * var(--u));
}

.rd-card-buy .rd-btn {
  width: 100%;
}

.rd-card-note {
  margin-top: calc(22 * var(--u));
  font-size: calc(32 * var(--u));
  color: var(--rd-info);
}

/* The bottom row (`itemBottom`): the price first, the Yellow cash symbol
   (50x30) before it, in Tooltip.textColor. */
.rd-card-bottom {
  display: flex;
  align-items: center;
  margin-top: calc(24 * var(--u));
  font-size: calc(40 * var(--u));
  color: var(--rd-red-price);
}

.rd-card-bottom .rd-eddies-sm {
  width: calc(50 * var(--u));
  height: calc(30 * var(--u));
  margin-right: calc(20 * var(--u));
}

/* ── buttons: the inventory's big button (`button_big1`) ────────────────── */

.rd-btn {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: calc(20 * var(--u));
  min-width: calc(380 * var(--u));
  height: calc(104 * var(--u));
  padding: 0 calc(40 * var(--u)) 0 calc(44 * var(--u)) !important;
  font-size: calc(42 * var(--u));
  font-weight: 600;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--rd-red) !important;
}

.rd-btn > span {
  position: relative;
}

.rd-btn > .rd-btn-bg,
.rd-btn > .rd-btn-fg {
  position: absolute;
  inset: 0;
  transition:
    background 0.12s,
    opacity 0.12s;
}

.rd-btn-bg {
  background: var(--rd-red-faint);
  opacity: 0.85;
  -webkit-mask-box-image: url('./art/btn_bg.png') 11 9 21 21 / calc(11 * var(--u)) calc(9 * var(--u)) calc(21 * var(--u)) calc(21 * var(--u));
}

.rd-btn-fg {
  background: var(--rd-red);
  opacity: 0.7;
  -webkit-mask-box-image: url('./art/btn_fg.png') 12 8 22 21 / calc(12 * var(--u)) calc(8 * var(--u)) calc(22 * var(--u)) calc(21 * var(--u));
}

.rd-btn:not(:disabled):hover {
  color: var(--rd-red-active) !important;
  text-shadow: 0 0 calc(14 * var(--u)) rgba(255, 113, 103, 0.55);
}

.rd-btn:not(:disabled):hover .rd-btn-bg {
  background: #5c1f27;
}

.rd-btn:not(:disabled):hover .rd-btn-fg {
  background: var(--rd-red-active);
  opacity: 1;
}

.rd-btn:disabled {
  opacity: 0.45;
}

.rd-btn.is-quiet {
  color: var(--rd-red-mild) !important;
}

.rd-btn.is-quiet .rd-btn-fg {
  opacity: 0.4;
}

.rd-btn.is-small {
  min-width: 0;
  height: calc(80 * var(--u));
  padding: 0 calc(26 * var(--u)) 0 calc(30 * var(--u)) !important;
  font-size: calc(32 * var(--u));
}

.rd-btn.is-done {
  color: var(--rd-blue) !important;
  opacity: 1;
}

.rd-btn.is-done .rd-btn-fg {
  background: var(--rd-blue);
  opacity: 0.5;
}

.rd-btn.is-done .rd-btn-bg {
  background: #0b2226;
}

.rd-btn-price {
  display: flex;
  align-items: center;
  font-weight: 500;
  color: var(--rd-red-price);
}

/* ── popups: the game's ripperdoc purchase popup (`purchase_popup`) ─────── */
/* Everything behind it darkened (Fullscreen_PrimaryBackgroundDarkest at 0.8);
   a column 1084 wide in the middle: the question (ReadableFontSize, Red), a
   hairline (Red at 0.05), the item, and the answers right-aligned under it. */

.rd-modal {
  position: absolute;
  inset: 0;
  z-index: 4;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(14, 14, 23, 0.86);
  -webkit-backdrop-filter: blur(calc(10 * var(--u)));
  backdrop-filter: blur(calc(10 * var(--u)));
}

/* The column is the item's width (29 + 863), so the answers line up with its
   right edge. */
.rd-pop {
  position: relative;
  width: calc(892 * var(--u));
}

.rd-pop-title {
  padding-left: calc(5 * var(--u));
  font-size: calc(50 * var(--u));
  line-height: calc(70 * var(--u));
  letter-spacing: 0.02em;
  text-transform: uppercase;
  color: var(--rd-red);
}

.rd-pop-rule {
  height: calc(2 * var(--u));
  margin-bottom: calc(28 * var(--u));
  background: var(--rd-red);
  opacity: 0.12;
}

.rd-pop-head {
  margin-top: calc(26 * var(--u));
  font-size: calc(38 * var(--u));
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--rd-blue);
}

.rd-pop-line {
  margin-top: calc(20 * var(--u));
  font-size: calc(42 * var(--u));
  line-height: 1.3;
  color: var(--rd-red);
}

.rd-pop-line.is-faint {
  color: var(--rd-info);
  opacity: 0.7;
}

.rd-pop-line.is-hot {
  color: var(--rd-red-active);
}

/* The item: `item_side_bg` in the tier's colour, `item_bg` / `item_fg` beside
   it (863x194), the picture at 75, the name (ReadableMedium, Red) and the price
   (the Yellow cash symbol, ReadableFontSize Semi-Bold) at the foot, right. */
.rd-buy-item {
  position: relative;
  width: calc(892 * var(--u));
  height: calc(194 * var(--u));
}

.rd-buy-item > span,
.rd-buy-item > img {
  position: absolute;
}

.rd-buy-side {
  left: 0;
  top: 0;
  bottom: 0;
  width: calc(24 * var(--u));
  background: var(--rd-rarity);
  -webkit-mask-box-image: url('./art/item_side.png') 10 8 90 10 / calc(10 * var(--u)) calc(8 * var(--u)) calc(90 * var(--u)) calc(10 * var(--u));
}

.rd-buy-bg,
.rd-buy-fg,
.rd-buy-iconic {
  left: calc(29 * var(--u));
  top: 0;
  right: 0;
  bottom: 0;
}

.rd-buy-bg {
  background: var(--rd-bg-darkest);
  -webkit-mask-box-image: url('./art/item_bg.png') 23 75 75 23 / calc(23 * var(--u)) calc(75 * var(--u)) calc(75 * var(--u)) calc(23 * var(--u));
}

.rd-buy-fg {
  background: var(--rd-red);
  opacity: 0.2;
  -webkit-mask-box-image: url('./art/item_fg.png') 23 75 75 23 / calc(23 * var(--u)) calc(75 * var(--u)) calc(75 * var(--u)) calc(23 * var(--u));
}

.rd-buy-iconic {
  right: auto;
  width: calc(194 * var(--u));
  background: var(--rd-iconic);
  opacity: 0.35;
  -webkit-mask-position: center;
  -webkit-mask-size: 100% 100%;
}

.rd-buy-icon {
  left: calc(60 * var(--u));
  top: calc(22 * var(--u));
  width: calc(210 * var(--u));
  height: calc(150 * var(--u));
  object-fit: contain;
}

.rd-buy-values {
  position: absolute;
  left: calc(300 * var(--u));
  right: calc(30 * var(--u));
  top: calc(25 * var(--u));
  bottom: calc(22 * var(--u));
  display: flex;
  flex-direction: column;
}

.rd-buy-name {
  font-size: calc(42 * var(--u));
  line-height: 1.2;
  letter-spacing: 0.02em;
  text-transform: uppercase;
  color: var(--rd-red);
}

.rd-buy-tier {
  margin-top: calc(6 * var(--u));
  font-size: calc(34 * var(--u));
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--rd-rarity);
}

.rd-buy-price {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  margin-top: auto;
  font-size: calc(50 * var(--u));
  font-weight: 600;
  line-height: 1;
  color: var(--rd-red);
}

.rd-buy-price .rd-eddies-sm {
  width: calc(50 * var(--u));
  height: calc(30 * var(--u));
  margin-right: calc(20 * var(--u));
}

.rd-pop-actions {
  display: flex;
  justify-content: flex-end;
  gap: calc(12 * var(--u));
  margin-top: calc(60 * var(--u));
}

/* A popup's answer (`purchase_popup_button`, 376x84): `cell_bg` in the darkest
   ground, `cell_fg` in Red at 0.1, the word in Blue (ReadableSmall). */
.rd-pbtn {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  width: calc(376 * var(--u));
  height: calc(84 * var(--u));
  font-size: calc(38 * var(--u));
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--rd-blue) !important;
}

.rd-pbtn > span {
  position: relative;
}

.rd-pbtn > .rd-pbtn-bg,
.rd-pbtn > .rd-pbtn-fg {
  position: absolute;
  inset: 0;
  transition: opacity 0.12s;
}

.rd-pbtn-bg {
  background: var(--rd-bg-darkest);
  -webkit-mask-box-image: url('./art/cell_bg.png') 20 30 30 20 / calc(20 * var(--u)) calc(30 * var(--u)) calc(30 * var(--u)) calc(20 * var(--u));
}

.rd-pbtn-fg {
  background: var(--rd-red);
  opacity: 0.1;
  -webkit-mask-box-image: url('./art/cell_fg.png') 20 30 30 20 / calc(20 * var(--u)) calc(30 * var(--u)) calc(30 * var(--u)) calc(20 * var(--u));
}

.rd-pbtn:not(:disabled):hover {
  color: var(--rd-blue-active) !important;
}

.rd-pbtn:not(:disabled):hover .rd-pbtn-fg {
  background: var(--rd-blue);
  opacity: 0.6;
}

.rd-pbtn:disabled {
  opacity: 0.4;
}

.rd-pbtn.is-small {
  width: auto;
  min-width: calc(300 * var(--u));
  height: calc(70 * var(--u));
  padding: 0 calc(30 * var(--u)) !important;
  font-size: calc(34 * var(--u));
}

.rd-invitee {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: calc(24 * var(--u));
  margin-top: calc(14 * var(--u));
  padding-bottom: calc(14 * var(--u));
  border-bottom: calc(2 * var(--u)) solid rgba(255, 97, 89, 0.12);
}

.rd-invitee-name {
  overflow: hidden;
  font-size: calc(42 * var(--u));
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--rd-red);
}

/* ── the warning box and the button hint ────────────────────────────────── */
/* The widget's own `warnning` panel: ActiveBlue on the darkest ground, in a
   blue frame. */

.rd-warn {
  position: absolute;
  left: 50%;
  z-index: 3;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: calc(10 * var(--u));
  max-width: calc(1800 * var(--u));
  padding: calc(26 * var(--u)) calc(70 * var(--u));
  transform: translateX(-50%);
  pointer-events: none;
}

.rd-warn::before,
.rd-warn::after {
  content: '';
  position: absolute;
  inset: 0;
}

.rd-warn::before {
  background: var(--rd-bg-darkest);
  opacity: 0.95;
  -webkit-mask-box-image: url('./art/cell_bg.png') 20 30 30 20 / calc(20 * var(--u)) calc(30 * var(--u)) calc(30 * var(--u)) calc(20 * var(--u));
}

.rd-warn::after {
  background: var(--rd-blue);
  opacity: 0.5;
  -webkit-mask-box-image: url('./art/cell_fg.png') 20 30 30 20 / calc(20 * var(--u)) calc(30 * var(--u)) calc(30 * var(--u)) calc(20 * var(--u));
}

.rd-warn-text {
  position: relative;
  z-index: 1;
  font-size: calc(40 * var(--u));
  line-height: 1.25;
  letter-spacing: 0.03em;
  text-transform: uppercase;
  text-align: center;
  color: var(--rd-blue-active);
}

.rd-warn-top {
  top: calc(18vh);
}

.rd-warn-bottom {
  bottom: calc(150 * var(--u));
}

.rd-hints {
  position: absolute;
  right: calc(100 * var(--u));
  bottom: calc(56 * var(--u));
  display: flex;
  gap: calc(40 * var(--u));
}

.rd-hint {
  display: flex;
  align-items: center;
  gap: calc(18 * var(--u));
  font-size: calc(42 * var(--u));
  letter-spacing: 0.03em;
  text-transform: uppercase;
  color: var(--rd-red) !important;
}

.rd-hint:hover {
  color: var(--rd-red-active) !important;
}

/* The key, in the game's label frame. */
.rd-key {
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
  min-width: calc(96 * var(--u));
  height: calc(58 * var(--u));
  padding: 0 calc(18 * var(--u));
  font-size: calc(32 * var(--u));
  font-weight: 600;
}

.rd-key::before {
  content: '';
  position: absolute;
  inset: 0;
  background: currentColor;
  -webkit-mask-box-image: url('./art/label_line.png') 13 30 13 30 / calc(13 * var(--u)) calc(30 * var(--u)) calc(13 * var(--u)) calc(30 * var(--u));
}
</style>
