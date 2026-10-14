<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { bool, list, num, table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'
import { GLYPHS } from '@/modules/target/glyphs'

/**
 * THE SKILL TREE -- seven trunks of job work, thirty-five nodes, and the one
 * currency a level banks.
 *
 * IT DECIDES NOTHING, the way no view here does. Which trunks exist, how deep
 * each has been fed, which nodes are yours and what a press would cost all
 * arrive from the server; this page draws the frame and reports presses. An
 * unlock is an INTENT (`skills:spend`) and the tree only redraws when a fresh
 * frame comes back -- a node bought in the page would be a second authority
 * over one fact.
 *
 * STOWING IS AN INTENT TOO. The close control, Escape and the stow key all ask
 * (`skills:close`, deduped like a spend); the panel goes down when the close
 * comes back on `skills:view`, exactly as the scanner waits for its own. The
 * tree is a MODAL and holds the keyboard, and on this platform no key mapping
 * fires while a page does -- so the stow key (the player's own binding, which
 * the frame carries) is caught HERE and asked for like any other close.
 *
 * -- WHY IT WAS REBUILT: "not showing all the skills, the page isn't big enough" --
 *
 * Both halves were true. The panel was `min(980px, ...)` at every surface size
 * -- the same small box at 1280 and at 2560 -- and each trunk got a ~305px
 * column of it. In that column a LOCKED row was `[ord][mark][name][why]` with
 * the name at `flex: 1` (basis 0) and the requirement sentence at its whole
 * width (~280px at the micro size), so the name was laid out at ZERO px and
 * the sentence cut: every locked node's name was 0px wide at 1280x720,
 * 1920x1080 and 2560x1440, in both languages.
 *
 * -- DESIGN, per ui/README.md, after the game's own PERKS screen --
 *
 * ONE SURFACE, SCALED WHOLE, NEVER REFLOWED. The tree is laid out on a
 * 1280x720 design surface and `transform: scale` takes it to the largest size
 * the screen holds -- 1.5x at 1080p, 2x at 1440p -- which is how the game
 * scales its own menus. Every one of the thirty-five nodes is on screen at
 * every 16:9 size from 720p up. The fit is a function of the window alone (no
 * measured element, so no loop between a size and the scale that reads it).
 * Another aspect ratio gets its spare room as LAYOUT, never as a smaller tree;
 * below 1280x720 the scale stays at 1 and the room scrolls, because shrinking
 * past the type scale buys a tree nobody can read.
 *
 * A TREE GROWS UP. Trunks are COLUMNS, in the config's order, and ranks are
 * ROWS from rank 1 at the foot to the capstones at the crown -- the game's
 * attribute gates (4 / 9 / 15 / 20) turned on end, with a gate on each row.
 * Each trunk's head is its ROOT, under its column: emblem, name, the work that
 * feeds it, its rank drawn and said, and its step toward the next. The node
 * at index i is the rank-i node: the server's own `rankOf`, so the row says
 * what the frame says.
 *
 * THE LAST TRUNK IS THE APEX. The config orders the trunks and the last one is
 * drawn as the top of the tree -- its column edged, its root framed and named
 * as the apex -- and its last node, the highest a character can climb, is the
 * legend: the one tile that stays lit even while it is locked, because it is
 * the goal the whole screen points at. No id is special-cased here.
 *
 * EACH TRUNK HAS ITS OWN MARK: its emblem and its feed line come from the
 * frame (config `ICON` / `FEED`), and a node's glyph is its perk's, falling
 * back to its trunk's emblem -- identity by picture and words, never by a
 * second hue (rule 7).
 *
 * CENTRED, so there is NO TILT (rule 5).
 *
 * A NODE THE WORK HAS NOT REACHED IS A READOUT, NOT A CONTROL (rule 2): no
 * closed frame and no ground -- four corner brackets around its name, and a
 * short line STATING ITS REQUIREMENT (the rank, the node below it, or the
 * points, restated from the server's own `why`; the whole sentence is in the
 * detail column). It is still pressable, because a readout you cannot ask
 * about is half a readout: a press INSPECTS and never offers the unlock. The
 * unlock is the one control, and it is only ever on a node the server called
 * `available`.
 *
 * THE WIRES ARE THE RANK, DRAWN UP THE TRUNK: idle red as far as its work has
 * reached, full red between claimed nodes, a dashed hairline past it.
 *
 * THE DETAIL COLUMN IS ALWAYS THERE, as the game's is: the name large, the
 * description with the perk's value lit (cut at the locale template's own
 * `{value}` -- the page never writes the sentence), the perk id, value, cost,
 * tier and trunk, the server's sentence for the state, and the one control.
 * With nothing picked it lists what the points can buy now.
 *
 * THE CHROME BAND is `frame.chrome` and `frame.cap`, both optional: a server
 * that sends neither gets the tree and no band. Every figure in it is the
 * frame's; the one number the page derives, the average gain per level, is
 * (at the cap - at level 1) / (cap - 1) of frame numbers, and says so.
 *
 * EVERY MICRO-LABEL STATES A REAL NUMBER (rule 8): gate ranks, each trunk's
 * rank and XP, node costs, the picked node's place in its trunk, the header's
 * level, XP, points and ready count. The buyable count is counted off the
 * frame's own node states -- nothing on this surface is a number the frame did
 * not carry or the page cannot count off it.
 *
 * NO TITLE. The screen does not name itself: the header opens on the level
 * and the chrome band on its figures. A "SKILL TREE" banner over a skill tree,
 * a trunk-and-node tally under it and a sentence explaining the band read as
 * filler, not as the game's UI (2026-09-28), and went.
 *
 * FRESHNESS IS THE HUE'S LUMINANCE DESCENT (rule 4): the ledger line is the
 * voice at full (`--op-red`) when it is news a player looks up for -- a level,
 * a node claimed -- and work credited settles at `--op-text-dim`.
 *
 * THE ENTRANCE IS THE STAGGER (`.op-enter` with `--op-slot`): roots first,
 * then the tiles climbing, so the tree grows in. A FRESH frame also sweeps the
 * detail column clean, and brings a tree taller than the screen to its roots.
 */

interface Node {
  id: string
  /** Locale KEYs, never sentences -- the page holds no English. */
  name: string
  desc: string
  perk: string
  value: number
  cost: number
  state: 'unlocked' | 'available' | 'locked'
  /** For a locked node: the locale key of the requirement it states. */
  why: string
}

interface Branch {
  id: string
  name: string
  /** The trunk's emblem, a name from the shared glyph set; '' for none. */
  icon: string
  /** The locale key of the line saying what work feeds it; '' for none. */
  feed: string
  rank: number
  /** XP into this trunk's CURRENT rank step, below `need`. */
  xp: number
  /** The trunk's step -- the denominator of the gauge this page draws. */
  need: number
  nodes: Node[]
}

interface Line {
  key: string
  args: Record<string, unknown>
  level: number
  points: number
}

/** A Sandevistan boost's two ends: the lowest grade's seconds and the top grade's. */
interface Span {
  lo: number
  hi: number
}

/** What the character level does for fitted chrome, as the frame said it. */
interface Chrome {
  /** Days a fitted piece lasts, fresh to broken with no use: now, at level 1, at the cap. */
  life: { now: number; base: number; max: number } | null
  /** The most use, damage and deaths take off one life, in days; 0 when unsaid. */
  wear: number
  /** A boost's seconds: now, at level 1, at the cap. */
  active: { now: Span; base: Span; max: Span } | null
}

/** One rank of one trunk: the node drawn there and how it is joined. */
interface Cell {
  tier: number
  node: Node | null
  /** The wire INTO this node from the one below it (or from the root). */
  wire: 'claimed' | 'reached' | 'dark'
}

interface Lane {
  branch: Branch
  cells: Cell[]
  /** The trunk's rank is its last node's: there is no next rank to fill toward. */
  top: boolean
  /** The last trunk: the top of the tree. */
  apex: boolean
}

interface Piece {
  text: string
  hot: boolean
}

const { t, has } = useLocale()

/** A press nobody can spend through twice: the double-click's own ceiling. */
const SPEND_DEDUPE_MS = 300
/** And a stow asked by two doors for one press is one ask. */
const STOW_DEDUPE_MS = 300

/** THE DESIGN SURFACE, in CSS px: the smallest screen the tree is drawn on
 *  whole, and the size everything below is written at before the fit. */
const DESIGN_WIDTH = 1280
const DESIGN_HEIGHT = 720
/** The street left around the panel, in design px -- it scales with it. */
const MARGIN = 16
/** 4x the design is a 5K surface; past it the tree stops growing. */
const FIT_CEILING = 4
/** The widest the layout goes, width over height: a 32:9 screen gets the tree
 *  centred at about 21:9, not wires a third of the screen long. */
const WIDEST = 2.4

/** Each shipped perk's picture, from the shared glyph vocabulary the menu,
 *  the toasts and the eye already draw from (no sprite, no font, no fetch).
 *  Distinct within a trunk; a perk this table never heard of draws its
 *  trunk's emblem. */
const PERK_GLYPHS: Record<string, string> = {
  'ncpd.vest': 'shield',
  'ncpd.reload': 'ammo',
  'ncpd.stealth': 'hidden',
  'ncpd.command': 'talk',
  'ncpd.response': 'warning',
  'maxtac.gforce': 'heart',
  'maxtac.boarding': 'door',
  'maxtac.drop': 'location',
  'maxtac.laser': 'eye',
  'maxtac.reaper': 'weapon',
  'corp.access': 'tag',
  'corp.expense': 'money',
  'corp.leverage': 'folder',
  'corp.budget': 'box',
  'corp.board': 'flag',
  'nomad.handling': 'vehicle',
  'nomad.clan': 'person',
  'nomad.cargo': 'box',
  'nomad.speed': 'arrow',
  'nomad.chief': 'world',
  'street.haggle': 'money',
  'street.sprint': 'bolt',
  'street.craft': 'tool',
  'street.scavenge': 'search',
  'street.cred': 'emote',
  'ripperdoc.precision': 'plus',
  'ripperdoc.triage': 'heal',
  'ripperdoc.calibration': 'gear',
  'ripperdoc.surgery': 'tool',
  'ripperdoc.mastery': 'server',
  'fixer.contacts': 'list',
  'fixer.cut': 'money',
  'fixer.afterlife': 'drink',
  'fixer.kingmaker': 'flag',
  'fixer.legend': 'star'
}
/** A trunk that names no emblem, and a perk whose trunk names none. */
const FALLBACK_GLYPH = 'gear'
/** The claimed tick and the pointer's left button: two marks the set lacks. */
const TICK = ['M5 12.5l4.5 4.5L19 7.5']
const MOUSE = ['M8 3h8a4 4 0 0 1 4 4v10a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4V7a4 4 0 0 1 4-4Z', 'M12 3v7M4 10h16']

const open = ref(false)
const level = ref(1)
const xp = ref(0)
const need = ref(1)
const points = ref(0)
const depth = ref(1)
/** The character level cap the frame named; 0 when it named none. */
const cap = ref(0)
/** The chrome the level buys, or null when the server runs no ripperdoc. */
const chrome = ref<Chrome | null>(null)
const branches = ref<Branch[]>([])
/** The stow cap says what the player's OWN binding says; Lua resolved it. */
const keycap = ref('F4')
/** The node under inspection -- the detail column's whole content. */
const picked = ref<{ branch: Branch; node: Node } | null>(null)
/** The newest line the ledger fed us, for the foot strip. */
const gain = ref<Line | null>(null)
/** Whether the tree has been scrolled off its roots (a tree taller or wider
 *  than the screen): the pinned roots and gates take a ground while it is. */
const slid = ref(false)
/** The tree's own scroll box, for bringing a tall tree to its roots. */
const scroller = ref<HTMLElement | null>(null)
/** When the last spend and the last stow left this page, and which node the
 *  spend named, for their dedupes. */
let lastSpend = 0
let lastSpent = ''
let lastStow = 0

let release: (() => void) | undefined

/** The window, as the fit reads it. */
const viewport = ref({ width: window.innerWidth, height: window.innerHeight })

function measure(): void {
  viewport.value = { width: window.innerWidth, height: window.innerHeight }
}

/** The scale: the largest the design surface can be drawn and still fit. */
const fit = computed(() => {
  const scale = Math.min(viewport.value.width / DESIGN_WIDTH, viewport.value.height / DESIGN_HEIGHT)
  return Math.min(FIT_CEILING, Math.max(1, Number.isFinite(scale) ? scale : 1))
})

/** The panel in design px, and the box its scaled picture occupies. The sizer
 *  is what the room centres and scrolls: a transform moves the paint and not
 *  the layout, so the layout has to be told the scaled size. */
const plane = computed(() => {
  const scale = fit.value
  const height = Math.max(DESIGN_HEIGHT, viewport.value.height / scale) - MARGIN * 2
  const width = Math.min(Math.max(DESIGN_WIDTH, viewport.value.width / scale) - MARGIN * 2, height * WIDEST)
  return {
    sizer: { width: `${width * scale}px`, height: `${height * scale}px` },
    unit: { width: `${width}px`, height: `${height}px`, transform: `scale(${scale})` }
  }
})

const levelText = computed(() => count(level.value))

const atCap = computed(() => cap.value > 0 && level.value >= cap.value)

/** Level progress as the header's gauge. One stroke, no second hue. */
const gauge = computed(() => {
  if (atCap.value) return '100%'
  const whole = Math.max(1, need.value)
  const into = Math.min(Math.max(0, xp.value), whole)
  return `${((into / whole) * 100).toFixed(1)}%`
})

/** What the points buy right now: every node the server called `available`. */
const ready = computed(() => {
  const out: { branch: Branch; node: Node }[] = []
  for (const branch of branches.value) {
    for (const node of branch.nodes) if (node.state === 'available') out.push({ branch, node })
  }
  return out
})

/** How many ranks the tree draws: the deepest trunk the frame carried, never
 *  fewer than the depth it declared. */
const tiers = computed(() => {
  let deepest = Math.max(1, depth.value)
  for (const branch of branches.value) deepest = Math.max(deepest, branch.nodes.length)
  return deepest
})

/** The ranks top-down, as the rows are drawn: the crown first. */
const tiersDown = computed(() => {
  const out: number[] = []
  for (let tier = tiers.value; tier >= 1; tier -= 1) out.push(tier)
  return out
})

/** Every trunk as the grid draws it: one cell per rank, each node wired in. */
const lanes = computed<Lane[]>(() =>
  branches.value.map((branch, at) => {
    const cells: Cell[] = []
    for (let index = 0; index < tiers.value; index += 1) {
      const node = branch.nodes[index] ?? null
      cells.push({ tier: index + 1, node, wire: node === null ? 'dark' : wireOf(branch, index) })
    }
    return {
      branch,
      cells,
      top: branch.rank >= branch.nodes.length,
      apex: at === branches.value.length - 1
    }
  })
)

/** The picked node's place in its trunk, 0-based. */
const pickedAt = computed(() => {
  const held = picked.value
  return held === null ? 0 : Math.max(0, held.branch.nodes.indexOf(held.node))
})

/** The average gain one level buys -- the only figure here the page derives,
 *  and from numbers the frame carried. Null without a cap to divide by. */
const perLevel = computed(() => {
  const held = chrome.value
  if (held === null || cap.value <= 1) return null
  const steps = cap.value - 1
  return {
    life: held.life === null ? null : (held.life.max - held.life.base) / steps,
    active:
      held.active === null
        ? null
        : {
            lo: (held.active.max.lo - held.active.base.lo) / steps,
            hi: (held.active.max.hi - held.active.base.hi) / steps
          }
  }
})

/** The level track, 1..cap: the lit share, and where NOW and NEXT sit. */
const track = computed(() => {
  if (cap.value <= 1) return null
  const span = cap.value
  const at = Math.min(Math.max(1, level.value), span)
  return {
    lit: `${(1 - at / span) * 100}%`,
    now: `${((at - 1) / span) * 100}%`,
    next: at < span ? `${(at / span) * 100}%` : null,
    // The NOW label hangs off whichever edge keeps it inside the track.
    label: at <= span / 2
      ? { left: `${((at - 1) / span) * 100}%` }
      : { right: `${((span - at) / span) * 100}%` },
    start: at > 2,
    end: at < span - 1
  }
})

function count(at: number): string {
  return String(at).padStart(2, '0')
}

/** A value as the detail column states it: a sign, then the number. */
function signed(value: number): string {
  return value >= 0 ? `+${figure(value, 2)}` : figure(value, 2)
}

/** A number as this surface prints it: at most `places` decimals, trailing
 *  zeros dropped, in the locale's own decimal mark. */
function figure(value: number, places = 1): string {
  const scale = Math.pow(10, places)
  let out = (Math.round(value * scale) / scale).toFixed(places)
  if (out.indexOf('.') !== -1) out = out.replace(/0+$/, '').replace(/\.$/, '')
  if (out === '-0') out = '0'
  return has('skills.decimal') ? out.replace('.', t('skills.decimal')) : out
}

function days(value: number, places = 1): string {
  return t('skills.chrome.days', { days: figure(value, places) })
}

function secs(span: Span, places = 1): string {
  const lo = figure(span.lo, places)
  const hi = figure(span.hi, places)
  return lo === hi ? t('skills.chrome.sec', { secs: lo }) : t('skills.chrome.secs', { lo, hi })
}

/** A per-level gain as the band states it: signed, two decimals at most. */
function gainDays(value: number): string {
  return t('skills.chrome.days', { days: (value > 0 ? '+' : '') + figure(value, 2) })
}

function gainSecs(span: Span): string {
  const lo = (span.lo > 0 ? '+' : '') + figure(span.lo, 2)
  const hi = figure(span.hi, 2)
  return figure(span.lo, 2) === hi ? t('skills.chrome.sec', { secs: lo }) : t('skills.chrome.secs', { lo, hi })
}

/** One trunk's step toward its next rank, as the gauge draws it. */
function trunkGauge(branch: Branch): string {
  if (branch.rank >= branch.nodes.length) return '100%'
  const whole = Math.max(1, branch.need)
  const into = Math.min(Math.max(0, branch.xp), whole)
  return `${((into / whole) * 100).toFixed(1)}%`
}

/** The wire into a node: lit full between claimed nodes, idle as far as the
 *  trunk's rank reaches, dark past it. */
function wireOf(branch: Branch, at: number): Cell['wire'] {
  const node = branch.nodes[at]
  const before = at > 0 ? branch.nodes[at - 1] : undefined
  if (node.state === 'unlocked' && (before === undefined || before.state === 'unlocked')) return 'claimed'
  return at + 1 <= branch.rank ? 'reached' : 'dark'
}

/** The wire drawn ABOVE the node at rank `tier`: the one into the node
 *  above it, or none at the crown. */
function wireAbove(lane: Lane, tier: number): Cell['wire'] | null {
  const above = lane.cells[tier]
  return above !== undefined && above.node !== null ? above.wire : null
}

function emblemOf(branch: Branch): string[] {
  return GLYPHS[branch.icon] ?? GLYPHS[FALLBACK_GLYPH] ?? []
}

function glyphOf(branch: Branch, node: Node): string[] {
  const own = PERK_GLYPHS[node.perk]
  return (own !== undefined ? GLYPHS[own] : undefined) ?? emblemOf(branch)
}

/** Whether a node is the legend: the last node of the apex trunk. */
/** A locked tile is drawn without the frame (see the tile's `data-augmented-ui`). */
function isLocked(node: Node): boolean {
  return node.state === 'locked'
}

function isLegend(lane: Lane, node: Node): boolean {
  return lane.apex && lane.branch.nodes[lane.branch.nodes.length - 1] === node
}

/** What a tile says under its name, from the node's state and the server's
 *  own reason -- restated short; the whole sentence is the detail column's. */
function stateLine(node: Node, at: number): string {
  if (node.state === 'unlocked') return t('skills.state.unlocked')
  if (node.state === 'available') return t('skills.state.available')
  if (node.why === 'skills.rank') return t('skills.req.rank', { rank: count(at + 1) })
  if (node.why === 'skills.prereq') return t('skills.req.prereq', { node: count(at) })
  if (node.why === 'skills.noPoints') return t('skills.req.points', { cost: node.cost })
  return t('skills.state.locked')
}

/** The sentence the detail column closes on: the server's, for every state. */
function verdict(node: Node): string {
  if (node.state === 'unlocked') return t('skills.unlocked')
  if (node.state === 'available') return t('skills.canBuy')
  return node.why ? t(node.why) : t('skills.state.locked')
}

/** The description, cut at its own `{value}` so the number can be lit. The
 *  sign before it and the unit after it travel with it: `+5%`, `+5 %`. */
function descParts(node: Node): Piece[] {
  const cuts = t(node.desc).split('{value}')
  const pieces: Piece[] = []
  cuts.forEach((cut, at) => {
    let body = cut
    if (at > 0) {
      const last = pieces[pieces.length - 1]
      const sign = last !== undefined && !last.hot ? /[+-]$/.exec(last.text) : null
      if (sign !== null && last !== undefined) last.text = last.text.slice(0, -1)
      const unit = /^ ?%/.exec(body)
      if (unit !== null) body = body.slice(unit[0].length)
      // The French space before a percent is a non-breaking one: `+30 %`
      // is one figure and never breaks across two lines.
      const tail = unit !== null ? unit[0].replace(' ', '\u00a0') : ''
      pieces.push({ text: (sign ? sign[0] : '') + figure(node.value, 2) + tail, hot: true })
    }
    if (body.length > 0) pieces.push({ text: body, hot: false })
  })
  return pieces.filter((piece) => piece.text.length > 0)
}

/** Locale arguments, coerced: `t` takes strings or numbers, nothing else. */
function vars(args: Record<string, unknown>): Record<string, string | number> {
  const out: Record<string, string | number> = {}
  for (const [name, value] of Object.entries(args)) {
    out[name] = typeof value === 'number' ? value : String(value ?? '')
  }
  return out
}

/** The ledger's strip: a level or a node is news to look up for (full hue);
 *  work credited settles at dim. */
function gainWords(line: Line): string {
  return line.level > 0
    ? t('skills.gain.level', { level: line.level, points: line.points })
    : t(line.key, vars(line.args))
}

/** A finite number, or null: the chrome block is optional field by field. */
function finite(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function spanOf(value: unknown): Span | null {
  const pair = list<unknown>(value)
  const lo = finite(pair[0])
  if (lo === null) return null
  const hi = finite(pair[1])
  return { lo, hi: hi === null ? lo : hi }
}

/** `frame.chrome`, read: null when the server sent none (no ripperdoc, or a
 *  server from before the band existed), and a missing end falls back to
 *  the value it has rather than inventing one. */
function chromeOf(value: unknown): Chrome | null {
  const raw = table(value)
  const lifeNow = finite(raw.lifeDays)
  const life =
    lifeNow === null
      ? null
      : {
          now: lifeNow,
          base: finite(raw.lifeBaseDays) ?? lifeNow,
          max: finite(raw.lifeMaxDays) ?? lifeNow
        }
  const activeNow = spanOf(raw.activeSeconds)
  const active =
    activeNow === null
      ? null
      : {
          now: activeNow,
          base: spanOf(raw.activeBaseSeconds) ?? activeNow,
          max: spanOf(raw.activeMaxSeconds) ?? activeNow
        }
  if (life === null && active === null) return null
  return { life, wear: Math.max(0, finite(raw.wearDays) ?? 0), active }
}

function blank(): void {
  open.value = false
  branches.value = []
  chrome.value = null
  picked.value = null
  gain.value = null
  slid.value = false
  release?.()
  release = undefined
}

/** The one intent: a node and nothing else -- what it costs is the server's.
 *  Deduped like every press here: one press-release pair is one spend, however
 *  many events the pointer model makes of it. The dedupe is the SAME node's --
 *  the next node up, bought the moment its answer lands, is a second intent. */
function spend(node: Node): void {
  if (!open.value || node.state !== 'available') return
  const now = Date.now()
  if (node.id === lastSpent && now - lastSpend < SPEND_DEDUPE_MS) return
  lastSpend = now
  lastSpent = node.id
  emit('opx:skills:spend', { node: node.id })
}

/** The stow, asked. One press that reaches two doors -- the key caught here
 *  and Escape, or the button and the key -- is one ask. */
function stow(): void {
  if (!open.value) return
  const now = Date.now()
  if (now - lastStow < STOW_DEDUPE_MS) return
  lastStow = now
  emit('opx:skills:close', {})
}

/** Inspecting is not deciding: every node opens the detail column, and the
 *  locked one answers with its requirement instead of an unlock. */
function select(branch: Branch, node: Node): void {
  if (!open.value) return
  picked.value = { branch, node }
}

/** The roots and gates take a ground only while the tree slides under them. */
function onScroll(): void {
  const region = scroller.value
  if (region === null) return
  slid.value = region.scrollLeft > 0 || region.scrollTop + region.clientHeight < region.scrollHeight - 1
}

/** A tree taller than the screen opens at its roots, where rank 1 is. */
function toRoots(): void {
  void nextTick(() => {
    const region = scroller.value
    if (region === null) return
    region.scrollTop = region.scrollHeight
    onScroll()
  })
}

/** THE STOW KEY, CAUGHT BY THE PAGE. While the tree holds the keyboard the
 *  platform fires no key mapping, so the player's own binding -- which the
 *  frame carries -- is heard here and asks to close like the button does. A
 *  held key's repeats are one press. The binding is a key NAME (`F4`, `K`),
 *  so it is matched against both what the key types and which key it is. */
function onKeyDown(event: KeyboardEvent): void {
  if (!open.value || event.repeat || event.defaultPrevented) return
  const bound = keycap.value.toUpperCase()
  if (bound === '') return
  const code = event.code || ''
  const names = [event.key || '', code, code.replace(/^(Key|Digit)/, '')].map((name) => name.toUpperCase())
  if (!names.includes(bound)) return
  event.preventDefault()
  stow()
}

useBridge('opx:skills:view', (payload: Payload) => {
  guard(
    'skills:view',
    () => {
      const kind = text(payload.kind)

      if (kind === 'frame') {
        const frame = table(payload.frame)
        const rows: Branch[] = []
        for (const entry of list<Payload>(frame.branches)) {
          const id = text(entry.id)
          if (!id) continue
          const nodes: Node[] = []
          // EVERY NODE THE FRAME CARRIED, with no page-side ceiling: the frame
          // is the server's own truth and the host's payload bound is the only
          // size it can arrive at. A slice here silently swallowed rows past the
          // cut -- a trunk with nine nodes showed eight and no one was told.
          for (const raw of list<Payload>(entry.nodes)) {
            const nodeId = text(raw.id)
            if (!nodeId) continue
            const state = text(raw.state)
            nodes.push({
              id: nodeId,
              name: text(raw.name, nodeId),
              desc: text(raw.desc),
              perk: text(raw.perk),
              value: num(raw.value),
              cost: num(raw.cost, 1),
              state:
                state === 'unlocked' || state === 'available' ? state : 'locked',
              why: text(raw.why)
            })
          }
          rows.push({
            id,
            name: text(entry.name, id),
            icon: text(entry.icon),
            feed: text(entry.feed),
            rank: num(entry.rank, 1),
            xp: num(entry.xp),
            need: Math.max(1, num(entry.need, 100)),
            nodes
          })
        }
        // Nothing to draw is not a tree: Lua only answers with the trunks the
        // config declares, so this is a frame that lost its contents.
        if (rows.length === 0) return

        branches.value = rows
        level.value = Math.max(1, num(frame.level, 1))
        xp.value = num(frame.xp)
        need.value = Math.max(1, num(frame.need, 1))
        points.value = Math.max(0, num(frame.points))
        depth.value = Math.max(1, num(frame.depth, 1))
        // Both optional: a server from before the chrome band sends neither,
        // and the tree draws without it.
        cap.value = Math.max(0, Math.floor(num(frame.cap)))
        chrome.value = chromeOf(frame.chrome)
        keycap.value = text(payload.key, 'F4')

        // A FRESH frame sweeps the strip clean before it draws: a tree that
        // just opened shows the tree, not whatever the last one left picked.
        const fresh = bool(payload.fresh)
        if (fresh) {
          picked.value = null
          gain.value = null
        }

        if (!open.value) {
          open.value = true
          release?.()
          release = acquireFocus({
            id: 'skills.tree',
            // Escape stows it -- the tree is a chart, not a decision, so
            // leaving is always allowed.
            onEscape: () => stow()
          })
        }
        if (fresh) toRoots()

        // A pick the frame no longer supports falls back to nothing; one the
        // frame still holds is rebound to the FRESH rows, state and all, so
        // the detail column never reads a stale frame.
        const held = picked.value
        if (held !== null) {
          const branch = rows.find((candidate) => candidate.id === held.branch.id)
          const node = branch?.nodes.find((candidate) => candidate.id === held.node.id)
          picked.value = branch !== undefined && node !== undefined ? { branch, node } : null
        }
        return
      }

      if (kind === 'gain') {
        const entry = table(payload.line)
        const key = text(entry.key)
        if (!key) return
        gain.value = { key, args: table(entry.args), level: num(entry.level), points: num(entry.points) }
        return
      }

      // `close` and anything this does not know: the reason is Lua's and it has
      // already said it. This page only takes the panel down.
      blank()
    },
    undefined
  )
})

onMounted(() => {
  measure()
  window.addEventListener('resize', measure)
  window.addEventListener('keydown', onKeyDown)
})

onUnmounted(() => {
  window.removeEventListener('resize', measure)
  window.removeEventListener('keydown', onKeyDown)
  release?.()
})
</script>

<template>
  <div class="room op-ink" :class="{ open }">
    <div v-if="open" class="tree op-plane">
      <div class="sizer" :style="plane.sizer">
        <div
          class="unit op-bay op-arete op-interlace"
          data-augmented-ui="tr-clip bl-clip border"
          :style="plane.unit"
        >
          <!-- THE TOP BAR: what the character is, what it holds to spend. -->
          <header class="top">
            <div class="level">
              <span class="op-eyebrow dim">{{ t('skills.levelWord') }}</span>
              <span class="level-read">
                <span class="level-num">{{ levelText }}</span>
                <span v-if="cap > 0" class="op-value level-cap">/{{ count(cap) }}</span>
              </span>
            </div>

            <div class="xp">
              <div class="op-eyebrow xp-read">
                <span class="dim">{{ t('skills.xp', { xp: Math.round(xp), need }) }}</span>
                <span class="xp-next">
                  {{ atCap ? t('skills.maxLevel') : t('skills.nextLevel', { level: count(level + 1) }) }}
                </span>
              </div>
              <div class="xp-track">
                <div class="xp-fill" :style="{ width: gauge }"></div>
              </div>
            </div>

            <div class="purse" :class="{ some: points > 0 }">
              <span class="op-eyebrow dim">{{ t('skills.pointsWord') }}</span>
              <span class="purse-read">
                <span class="purse-num">{{ count(points) }}</span>
                <span class="op-eyebrow purse-ready">{{ t('skills.ready', { count: count(ready.length) }) }}</span>
              </span>
            </div>

            <button type="button" class="stow op-frame" data-augmented-ui="tr-clip border" @click="stow()">
              {{ t('skills.stow', { key: keycap }) }}
            </button>
          </header>

          <!-- THE TREE: trunks across, ranks climbing, the roots at its foot. -->
          <section class="forest">
            <div
              ref="scroller"
              class="scroller"
              :class="{ slid }"
              :style="{ '--trunks': lanes.length }"
              @scroll="onScroll"
            >
              <div class="grid">
                <div v-for="tier in tiersDown" :key="tier" class="rank" :data-tier="tier">
                  <span class="gate" aria-hidden="true">
                    <span class="op-eyebrow">{{ t('skills.gate', { rank: count(tier) }) }}</span>
                  </span>
                  <div
                    v-for="(lane, bi) in lanes"
                    :key="lane.branch.id"
                    class="cell"
                    :class="{ apex: lane.apex }"
                  >
                    <template v-if="lane.cells[tier - 1].node">
                      <span
                        v-if="wireAbove(lane, tier)"
                        class="wire"
                        :class="wireAbove(lane, tier)"
                      ></span>
                      <button
                        type="button"
                        class="tile op-enter"
                        :data-node-id="lane.cells[tier - 1].node!.id"
                        :data-state="lane.cells[tier - 1].node!.state"
                        :class="{
                          'op-frame': lane.cells[tier - 1].node!.state !== 'locked',
                          'op-arete': lane.cells[tier - 1].node!.state === 'available',
                          'is-on': lane.cells[tier - 1].node!.state === 'unlocked',
                          shut: lane.cells[tier - 1].node!.state === 'locked',
                          legend: isLegend(lane, lane.cells[tier - 1].node!),
                          'is-picked': picked?.node.id === lane.cells[tier - 1].node!.id,
                          'op-lift':
                            (picked?.node.id === lane.cells[tier - 1].node!.id
                              || isLegend(lane, lane.cells[tier - 1].node!))
                            && lane.cells[tier - 1].node!.state !== 'locked'
                        }"
                        :data-augmented-ui="isLocked(lane.cells[tier - 1].node!) ? undefined : 'tr-clip border'"
                        :style="{ '--op-slot': Math.min(12, bi + tier) }"
                        @click="select(lane.branch, lane.cells[tier - 1].node!)"
                      >
                        <span class="tile-top">
                          <svg class="glyph" viewBox="0 0 24 24" aria-hidden="true">
                            <path v-for="(d, di) in glyphOf(lane.branch, lane.cells[tier - 1].node!)" :key="di" :d="d" />
                          </svg>
                          <span class="op-eyebrow cost">{{ t('skills.cost', { cost: lane.cells[tier - 1].node!.cost }) }}</span>
                        </span>
                        <span class="tile-name">{{ t(lane.cells[tier - 1].node!.name) }}</span>
                        <span class="op-eyebrow state">
                          <svg
                            v-if="lane.cells[tier - 1].node!.state !== 'available'"
                            class="mark"
                            viewBox="0 0 24 24"
                            aria-hidden="true"
                          >
                            <path
                              v-for="(d, di) in lane.cells[tier - 1].node!.state === 'unlocked' ? TICK : GLYPHS.lock"
                              :key="di"
                              :d="d"
                            />
                          </svg>
                          <span class="op-truncate">{{ stateLine(lane.cells[tier - 1].node!, tier - 1) }}</span>
                        </span>
                      </button>
                    </template>
                  </div>
                </div>

                <!-- THE ROOTS: each trunk's head, under its column. -->
                <div class="roots">
                  <span class="gate-pad"></span>
                  <header
                    v-for="(lane, bi) in lanes"
                    :key="lane.branch.id"
                    class="trunk op-enter"
                    :class="{ apex: lane.apex, 'op-bay': lane.apex, 'op-interlace': lane.apex }"
                    :data-branch-id="lane.branch.id"
                    :data-augmented-ui="lane.apex ? 'tr-clip bl-clip border' : undefined"
                    :style="{ '--op-slot': bi }"
                  >
                    <span class="wire lead" :class="lane.cells[0].node ? lane.cells[0].wire : 'dark'"></span>
                    <span class="trunk-top">
                      <svg class="emblem" viewBox="0 0 24 24" aria-hidden="true">
                        <path v-for="(d, di) in emblemOf(lane.branch)" :key="di" :d="d" />
                      </svg>
                      <span class="trunk-name op-truncate">{{ t(lane.branch.name) }}</span>
                      <span v-if="lane.apex" class="op-eyebrow apex-chip">{{ t('skills.apex') }}</span>
                    </span>
                    <span v-if="lane.branch.feed" class="trunk-feed op-truncate">{{ t(lane.branch.feed) }}</span>
                    <span class="segs" aria-hidden="true">
                      <span
                        v-for="r in lane.branch.nodes.length"
                        :key="r"
                        class="seg"
                        :class="{ on: r <= lane.branch.rank }"
                      >
                        <span
                          v-if="r === lane.branch.rank + 1"
                          class="seg-fill"
                          :style="{ width: trunkGauge(lane.branch) }"
                        ></span>
                      </span>
                    </span>
                    <span class="op-eyebrow trunk-rank op-truncate">
                      {{ t('skills.trunkRank', { rank: count(lane.branch.rank), depth: count(lane.branch.nodes.length) }) }}
                    </span>
                    <span class="op-eyebrow dim op-truncate">
                      {{
                        lane.top
                          ? t('skills.trunkMax')
                          : t('skills.xp', { xp: Math.round(lane.branch.xp), need: lane.branch.need })
                      }}
                    </span>
                  </header>
                </div>
              </div>
            </div>

            <!-- THE LEVEL BONUS: what the character level does for fitted chrome. -->
            <section v-if="chrome" class="band">
              <div class="band-title">
                <span class="op-label band-name op-truncate">{{ t('skills.chrome.title') }}</span>
                <span class="op-eyebrow band-at op-truncate">
                  {{ cap > 0 ? t('skills.chrome.at', { level: levelText, cap: count(cap) }) : t('skills.level', { level: levelText }) }}
                </span>
              </div>

              <div v-if="chrome.life" class="stat" data-stat="life">
                <span class="op-eyebrow dim op-truncate">{{ t('skills.chrome.life') }}</span>
                <span class="stat-head">
                  <span class="stat-now">{{ days(chrome.life.now) }}</span>
                  <span class="op-eyebrow stat-step op-truncate">
                    {{
                      atCap
                        ? t('skills.chrome.maxed')
                        : perLevel && perLevel.life !== null
                          ? t('skills.chrome.perLevel', { value: gainDays(perLevel.life) })
                          : ''
                    }}
                  </span>
                </span>
                <span class="op-eyebrow dim stat-ends">
                  <span>{{ t('skills.chrome.atLevel', { level: count(1), value: days(chrome.life.base) }) }}</span>
                  <span>
                    {{
                      cap > 0
                        ? t('skills.chrome.atLevel', { level: count(cap), value: days(chrome.life.max) })
                        : t('skills.chrome.atMax', { value: days(chrome.life.max) })
                    }}
                  </span>
                </span>
                <span v-if="chrome.wear > 0" class="op-eyebrow dim op-truncate">
                  {{ t('skills.chrome.wear', { days: days(chrome.wear) }) }}
                </span>
              </div>

              <div v-if="chrome.active" class="stat" data-stat="active">
                <span class="op-eyebrow dim op-truncate">{{ t('skills.chrome.active') }}</span>
                <span class="stat-head">
                  <span class="stat-now">{{ secs(chrome.active.now) }}</span>
                  <span class="op-eyebrow stat-step op-truncate">
                    {{
                      atCap
                        ? t('skills.chrome.maxed')
                        : perLevel && perLevel.active !== null
                          ? t('skills.chrome.perLevel', { value: gainSecs(perLevel.active) })
                          : ''
                    }}
                  </span>
                </span>
                <span class="op-eyebrow dim stat-ends">
                  <span>{{ t('skills.chrome.atLevel', { level: count(1), value: secs(chrome.active.base) }) }}</span>
                  <span>
                    {{
                      cap > 0
                        ? t('skills.chrome.atLevel', { level: count(cap), value: secs(chrome.active.max) })
                        : t('skills.chrome.atMax', { value: secs(chrome.active.max) })
                    }}
                  </span>
                </span>
              </div>

              <div v-if="track" class="track" data-stat="track">
                <!-- The next level is the header's to say; here it is the outlined
                     cell, and the word stays one label wide in either language. -->
                <span class="op-eyebrow track-head">
                  <span class="dim op-truncate">{{ t('skills.chrome.track') }}</span>
                </span>
                <div class="track-bar" :style="{ '--cells': cap }">
                  <div class="track-lit" :style="{ clipPath: `inset(0 ${track.lit} 0 0)` }"></div>
                  <div class="track-now" :style="{ left: track.now }"></div>
                  <div v-if="track.next" class="track-cue" :style="{ left: track.next }"></div>
                </div>
                <span class="op-eyebrow dim track-ends">
                  <span v-if="track.start" class="track-start">{{ count(1) }}</span>
                  <span class="track-here" :style="track.label">{{ levelText }}</span>
                  <span v-if="track.end" class="track-end">{{ count(cap) }}</span>
                </span>
              </div>
            </section>
          </section>

          <!-- THE DETAIL COLUMN: what the picked node is, and the one control. -->
          <aside class="side" :data-picked="picked ? picked.node.id : ''">
            <template v-if="picked">
              <div class="op-eyebrow dim op-truncate">
                {{
                  t('skills.where', {
                    trunk: t(picked.branch.name),
                    node: count(pickedAt + 1),
                    of: count(picked.branch.nodes.length)
                  })
                }}
              </div>

              <div
                class="plate op-bay op-interlace"
                :class="'is-' + picked.node.state"
                data-augmented-ui="tr-clip bl-clip border"
              >
                <svg class="plate-glyph" viewBox="0 0 24 24" aria-hidden="true">
                  <path v-for="(d, di) in glyphOf(picked.branch, picked.node)" :key="di" :d="d" />
                </svg>
                <div class="plate-read">
                  <span class="op-eyebrow dim">{{ t('skills.gate', { rank: count(pickedAt + 1) }) }}</span>
                  <span class="stamp op-truncate">{{ t('skills.state.' + picked.node.state) }}</span>
                  <span class="op-eyebrow plate-cost">{{ t('skills.cost', { cost: picked.node.cost }) }}</span>
                </div>
              </div>

              <div class="detail-name">{{ t(picked.node.name) }}</div>
              <p class="op-copy desc">
                <span
                  v-for="(piece, pi) in descParts(picked.node)"
                  :key="pi"
                  :class="{ hl: piece.hot }"
                >{{ piece.text }}</span>
              </p>

              <dl class="facts">
                <div class="fact">
                  <dt class="op-eyebrow dim">{{ t('skills.fact.perk') }}</dt>
                  <dd class="op-value op-truncate">{{ picked.node.perk }}</dd>
                </div>
                <div class="fact">
                  <dt class="op-eyebrow dim">{{ t('skills.fact.value') }}</dt>
                  <dd class="op-value hl">{{ signed(picked.node.value) }}</dd>
                </div>
                <div class="fact">
                  <dt class="op-eyebrow dim">{{ t('skills.fact.cost') }}</dt>
                  <dd class="op-value op-truncate">
                    {{ t('skills.cost', { cost: picked.node.cost }) }} ·
                    {{ t('skills.inHand', { points: count(points) }) }}
                  </dd>
                </div>
                <div class="fact">
                  <dt class="op-eyebrow dim">{{ t('skills.fact.tier') }}</dt>
                  <dd class="op-value op-truncate">
                    {{ t('skills.gate', { rank: count(pickedAt + 1) }) }} ·
                    {{ pickedAt + 1 <= picked.branch.rank ? t('skills.reached') : t('skills.unreached') }}
                  </dd>
                </div>
                <div class="fact">
                  <dt class="op-eyebrow dim">{{ t('skills.fact.trunk') }}</dt>
                  <dd class="op-value op-truncate">
                    {{
                      picked.branch.rank >= picked.branch.nodes.length
                        ? t('skills.trunkMax')
                        : t('skills.trunkState', {
                            rank: count(picked.branch.rank),
                            xp: Math.round(picked.branch.xp),
                            need: picked.branch.need
                          })
                    }}
                  </dd>
                </div>
              </dl>

              <div class="act">
                <p class="op-copy verdict" :class="picked.node.state">{{ verdict(picked.node) }}</p>
                <button
                  v-if="picked.node.state === 'available'"
                  type="button"
                  class="buy op-frame op-arete"
                  data-augmented-ui="tr-clip border"
                  @click="spend(picked.node)"
                >
                  <svg class="buy-mouse" viewBox="0 0 24 24" aria-hidden="true">
                    <path v-for="(d, di) in MOUSE" :key="di" :d="d" />
                  </svg>
                  <span class="op-truncate">{{ t('skills.spend', { cost: picked.node.cost }) }}</span>
                </button>
              </div>
            </template>

            <template v-else>
              <div class="op-label">{{ t('skills.detail') }}</div>
              <p class="op-copy dim">{{ t('skills.detailHint') }}</p>
              <div class="op-eyebrow dim ready-head">
                {{ t('skills.readyList') }} · {{ count(ready.length) }}
              </div>
              <div class="ready">
                <button
                  v-for="entry in ready"
                  :key="entry.node.id"
                  type="button"
                  class="quick op-frame"
                  data-augmented-ui="tr-clip border"
                  :data-quick-id="entry.node.id"
                  @click="select(entry.branch, entry.node)"
                >
                  <svg class="quick-glyph" viewBox="0 0 24 24" aria-hidden="true">
                    <path v-for="(d, di) in glyphOf(entry.branch, entry.node)" :key="di" :d="d" />
                  </svg>
                  <span class="quick-text">
                    <span class="quick-name op-truncate">{{ t(entry.node.name) }}</span>
                    <span class="op-eyebrow dim op-truncate">{{ t(entry.branch.name) }}</span>
                  </span>
                  <span class="op-eyebrow cost">{{ t('skills.cost', { cost: entry.node.cost }) }}</span>
                </button>
                <p v-if="ready.length === 0" class="op-copy dim">{{ t('skills.readyNone') }}</p>
              </div>
            </template>
          </aside>

          <!-- THE FOOT: the ledger's newest line, and the input hints. -->
          <footer class="foot">
            <div class="ledger">
              <span
                v-if="gain"
                class="op-eyebrow gain op-truncate"
                :class="{ hot: gain.level > 0 || gain.key === 'skills.gain.node' }"
              >{{ gainWords(gain) }}</span>
            </div>
            <div class="hints">
              <span class="hint">
                <kbd class="cap op-cap" data-augmented-ui="tr-clip border">
                  <svg class="cap-mouse" viewBox="0 0 24 24" aria-hidden="true">
                    <path v-for="(d, di) in MOUSE" :key="di" :d="d" />
                  </svg>
                </kbd>
                <span class="op-eyebrow">{{ t('skills.hint.select') }}</span>
              </span>
              <span class="hint" :class="{ idle: picked?.node.state !== 'available' }">
                <kbd class="cap op-cap" data-augmented-ui="tr-clip border">
                  <svg class="cap-mouse" viewBox="0 0 24 24" aria-hidden="true">
                    <path v-for="(d, di) in MOUSE" :key="di" :d="d" />
                  </svg>
                </kbd>
                <span class="op-eyebrow">{{ t('skills.hint.buy') }}</span>
              </span>
              <span class="hint">
                <kbd class="cap op-cap" data-augmented-ui="tr-clip border">{{ keycap }}</kbd>
                <kbd class="cap op-cap" data-augmented-ui="tr-clip border">{{ t('skills.cap.esc') }}</kbd>
                <span class="op-eyebrow">{{ t('skills.hint.close') }}</span>
              </span>
            </div>
          </footer>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* Centred and unrotated (rule 5): a chart read head-on, not a device held up
   at an angle. The room SCROLLS only below the design surface (1280x720),
   where the fit stops shrinking: `margin: auto` on the plane is the safe
   centring -- a flex `center` would push the overflow off the top and left,
   where no scroll can reach it.

   THE ROOM IS THE SCRIM, as the spawn menu's and the form's are: a modal over
   nearly the whole screen, so the world behind it stops looking like
   something the player can still act on -- and the scrim under the panel's
   own quiet ground is what holds its type against a daylight street. */
.room {
  position: fixed;
  inset: 0;
  display: flex;
  overflow: auto;
  overscroll-behavior: contain;
  background: var(--op-plate-quiet);
  opacity: 0;
  visibility: hidden;
  transition:
    opacity var(--op-dur) var(--op-ease),
    visibility var(--op-dur);
}

.room.open {
  opacity: 1;
  visibility: visible;
}

.tree {
  flex: none;
  margin: auto;
}

/* The box the scaled panel's PICTURE occupies. A transform moves paint, not
   layout, so this is what the room centres and measures. */
.sizer {
  position: relative;
}

/* THE PANEL, in design px, scaled whole from its top-left corner. Every size
   below is written for the 1280x720 surface and the fit multiplies it. */
.unit {
  position: absolute;
  top: 0;
  left: 0;
  transform-origin: 0 0;
  box-sizing: border-box;
  display: grid;
  grid-template-columns: minmax(0, 1fr) var(--side-w);
  grid-template-rows: auto minmax(0, 1fr) auto;
  grid-template-areas:
    'top top'
    'tree side'
    'foot foot';
  column-gap: var(--op-space-5);
  row-gap: 10px;
  padding: 12px var(--op-space-5) 10px;
  --aug-tl: var(--op-cut-lg);
  --aug-br: var(--op-cut-lg);
  background: var(--op-plate-quiet);
  /* The tree's own measures, in one place. Seven columns of 122 and the gate
     fit beside the detail column at 1280; 116 holds the widest word either
     catalogue puts on a tile (COMMANDEMENT, 97px at the name's size) inside
     the padding; five ranks of 76 (a tile and its wire) and the roots fit the
     720p surface with the chrome band under them. */
  --side-w: 240px;
  --gate-w: 44px;
  --col-min: 122px;
  --tile-w: 116px;
  --tile-h: 70px;
  --rank-min: 76px;
  --roots-h: 86px;
}

/* ROOM FOR AN ACCENT. A label cut to its box is clipped AT that box, and at
   the type scale's tight line-heights the box ends inside the font's own
   ascent -- where the accent over a capital lives. French SIÈGE drew as SIEGE
   at 1x and APRÈS as APRES, the labels still fitting and still laid out, so
   nothing measured it. A fifth of an em of padding above and below, paid back
   by the margin, moves the clip past the marks and moves nothing else. */
.unit .op-truncate,
.tile-name,
.detail-name {
  padding-block: 0.2em;
  margin-block: -0.2em;
}

/* Every READABLE readout is at `--op-text-dim`, not `--op-text-faint`: the
   faint tone measured 3.93:1 against this plate, under the 4.5 floor the tree's
   own harness sets, and a micro-label is still a sentence a player reads. */
.dim {
  color: var(--op-text-dim);
}

/* ── the top bar ─────────────────────────────────────────────────────────── */
.top {
  grid-area: top;
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto auto;
  align-items: end;
  column-gap: var(--op-space-6);
  padding-bottom: 8px;
  border-bottom: 1px solid var(--op-line);
}

/* The level and the points are the two numbers the whole screen is about, so
   they are the only type at the hero size, each behind the house rule. */
.level,
.purse {
  display: flex;
  flex-direction: column;
  gap: 2px;
  padding-left: var(--op-space-3);
  border-left: var(--op-rule) solid var(--op-red);
}

.level-read,
.purse-read {
  display: flex;
  align-items: baseline;
  gap: var(--op-space-2);
}

.level-num,
.purse-num {
  font: 700 var(--op-fs-hero) / 0.9 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  font-variant-numeric: tabular-nums;
}

.level-num {
  color: var(--op-red-hi);
}

.level-cap {
  color: var(--op-text-dim);
}

.xp {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-2);
  min-width: 0;
  padding-bottom: 5px;
}

.xp-read {
  display: flex;
  justify-content: space-between;
  gap: var(--op-space-3);
}

.xp-next {
  color: var(--op-red-text);
}

/* The gauge is the HUD's own: one stroke brightening across a track, the fill
   being the voice and nothing louder. The tick every tenth is the track's. */
.xp-track {
  position: relative;
  height: 6px;
  background:
    repeating-linear-gradient(90deg, transparent 0 calc(10% - 1px), var(--op-plate) calc(10% - 1px) 10%),
    var(--op-line);
}

.xp-fill {
  height: 100%;
  background: var(--op-red);
  box-shadow: 0 0 6px var(--op-red-glow);
  transition: width var(--op-dur) var(--op-ease);
}

.purse-num {
  color: var(--op-text-dim);
}

.purse.some .purse-num {
  color: var(--op-text);
}

.purse-ready {
  color: var(--op-red-text);
}

.stow {
  align-self: start;
  padding: var(--op-space-2) var(--op-space-4);
  font-family: var(--op-font-display);
  font-size: var(--op-fs-label);
  font-weight: 700;
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: var(--op-text);
  cursor: pointer;
  appearance: none;
  -webkit-appearance: none;
  border: 0;
}

/* ── the tree ────────────────────────────────────────────────────────────── */
.forest {
  grid-area: tree;
  display: flex;
  flex-direction: column;
  gap: 10px;
  min-width: 0;
  min-height: 0;
}

/* THE SCROLL REGION FOR A TREE BIGGER THAN THE SCREEN, and only for that: at
   the shipped seven trunks of five it never scrolls. The bar is drawn thin in
   the house tone -- a Chromium scrollbar over gameplay is the one thing the
   owner asked never to see again, and hiding it would hide that there is
   more. Scrolling into view keeps clear of the pinned roots and gates. */
.scroller {
  flex: 1 1 auto;
  min-height: 0;
  overflow: auto;
  overscroll-behavior: contain;
  scroll-padding-left: var(--gate-w);
  scroll-padding-bottom: var(--roots-h);
}

.scroller::-webkit-scrollbar,
.room::-webkit-scrollbar {
  width: 6px;
  height: 6px;
}

.scroller::-webkit-scrollbar-thumb,
.room::-webkit-scrollbar-thumb {
  background: var(--op-red-idle);
}

.scroller::-webkit-scrollbar-track,
.scroller::-webkit-scrollbar-corner,
.room::-webkit-scrollbar-track,
.room::-webkit-scrollbar-corner {
  background: transparent;
}

.grid {
  display: flex;
  flex-direction: column;
  min-height: 100%;
  min-width: calc(var(--gate-w) + var(--trunks) * var(--col-min));
}

/* One template for every rank and the roots, so the columns line up without a
   subgrid: a gate column and one equal column per trunk. */
.rank,
.roots {
  display: grid;
  grid-template-columns: var(--gate-w) repeat(var(--trunks), minmax(var(--col-min), 1fr));
}

/* The auto margin sits a short tree on its roots and falls to zero when the
   tree is taller than the region -- the safe way, since this region scrolls. */
.rank {
  position: relative;
  flex: 1 1 0;
  min-height: var(--rank-min);
}

.rank:first-child {
  margin-top: auto;
}

/* THE GATE between two ranks: a faint line across the tree where the rank
   below ends, a diamond where it meets the gate column. */
.rank + .rank::before {
  content: '';
  position: absolute;
  left: 8px;
  right: 0;
  top: 0;
  height: 1px;
  background: var(--op-line);
  opacity: 0.45;
}

.gate {
  position: sticky;
  left: 0;
  z-index: 3;
  display: flex;
  align-items: flex-end;
  padding-bottom: calc(var(--tile-h) / 2 - 11px);
  color: var(--op-text-dim);
}

.gate::after {
  content: '';
  position: absolute;
  left: 0;
  bottom: calc(var(--tile-h) / 2 - 4px);
  width: 7px;
  height: 7px;
  box-sizing: border-box;
  transform: rotate(45deg);
  border: 1px solid var(--op-red-idle);
  background: var(--op-plate);
}

/* The word over the number: `RANK 05` breaks at its one space, so the label
   holds the narrow gate column in either language and never reaches the
   tiles beside it. */
.gate .op-eyebrow {
  width: min-content;
  padding-left: 13px;
  line-height: 1.25;
}

.cell {
  position: relative;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: flex-end;
  min-width: 0;
}

/* THE APEX COLUMN is edged, not filled (rule 1): two red hairlines down the
   last trunk, from its root to its crown. */
.cell.apex {
  box-shadow:
    inset 1px 0 0 rgba(var(--op-red-idle-rgb), 0.35),
    inset -1px 0 0 rgba(var(--op-red-idle-rgb), 0.35);
}

/* THE WIRE up to the node above. Dark past the trunk's rank (a dashed
   hairline), idle red as far as the work has reached, full red between
   claimed nodes. */
.wire {
  flex: 1 1 auto;
  width: 2px;
  min-height: 6px;
  background: repeating-linear-gradient(180deg, var(--op-line) 0 4px, transparent 4px 8px);
}

.wire.reached {
  background: var(--op-red-idle);
}

.wire.claimed {
  background: var(--op-red);
  box-shadow: 0 0 6px var(--op-red-glow);
}

/* ── the tiles ───────────────────────────────────────────────────────────── */
.tile {
  flex: none;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  gap: 2px;
  width: var(--tile-w);
  height: var(--tile-h);
  padding: 6px 8px 6px;
  text-align: left;
  cursor: pointer;
  /* A BUTTON IS A USER-AGENT OBJECT until told otherwise: the host paints its
     own light ground and bevel behind every one. `appearance` off and NO
     ground here -- the ground is the state's to give: `op-frame` (a control,
     rule 2) or the brackets of `.shut` below (a readout), whose `background`
     shorthand also takes the host's ground away. */
  appearance: none;
  -webkit-appearance: none;
  border: 0;
  color: inherit;
  font: inherit;
}

.tile-top {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
}

.glyph {
  width: 18px;
  height: 18px;
  fill: none;
  stroke: currentcolor;
  stroke-width: 1.7;
  stroke-linecap: round;
  stroke-linejoin: round;
}

/* A name is a label, but a tile is two lines tall on purpose: the longest
   French name is two short lines, and a clamp -- not a cut -- keeps both. */
.tile-name {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  overflow: hidden;
  font: 700 13px / 1.05 var(--op-font-display);
  letter-spacing: var(--op-track-lead);
  text-transform: uppercase;
  color: var(--op-text);
  overflow-wrap: anywhere;
}

/* The state line gets the tile's whole width: the requirement a locked node
   states is the longest thing on it, and it must not share its row. */
.state {
  display: flex;
  align-items: center;
  gap: 4px;
  min-width: 0;
}

.mark {
  flex: none;
  width: 10px;
  height: 10px;
  fill: none;
  stroke: currentcolor;
  stroke-width: 2.2;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.cost {
  flex: none;
  color: var(--op-red-text);
}

/* AVAILABLE: the control with the lit leading edge -- the tile the eye should
   land on. */
.tile.op-arete .glyph {
  color: var(--op-red);
}

.tile.op-arete .state {
  color: var(--op-red-text);
}

/* CLAIMED: the frame at full and the plate lit (`.is-on`), the name in the
   brightest rung -- yours, and the tree says so first. */
.tile.is-on .glyph,
.tile.is-on .tile-name {
  color: var(--op-red-hi);
}

.tile.is-on .state {
  color: var(--op-red);
}

.tile.is-on .cost {
  color: var(--op-text-dim);
}

/* LOCKED: a readout, not a control (rule 2) -- four corner brackets and no
   ground, the bay showing through. Dim but readable: the name clears the
   4.5 floor at `--op-text-dim`; only the glyph, which is decoration, is
   faint. */
.tile.shut {
  --bracket: var(--op-line);
  background:
    linear-gradient(var(--bracket), var(--bracket)) left top / 10px 1px no-repeat,
    linear-gradient(var(--bracket), var(--bracket)) left top / 1px 10px no-repeat,
    linear-gradient(var(--bracket), var(--bracket)) right top / 10px 1px no-repeat,
    linear-gradient(var(--bracket), var(--bracket)) right top / 1px 10px no-repeat,
    linear-gradient(var(--bracket), var(--bracket)) left bottom / 10px 1px no-repeat,
    linear-gradient(var(--bracket), var(--bracket)) left bottom / 1px 10px no-repeat,
    linear-gradient(var(--bracket), var(--bracket)) right bottom / 10px 1px no-repeat,
    linear-gradient(var(--bracket), var(--bracket)) right bottom / 1px 10px no-repeat;
}

.tile.shut .glyph {
  color: var(--op-text-faint);
}

.tile.shut .tile-name,
.tile.shut .state,
.tile.shut .cost {
  color: var(--op-text-dim);
}

.tile.shut:hover {
  --bracket: var(--op-text-dim);
}

/* THE LEGEND -- the apex trunk's last node -- is the goal the screen points
   at, so it stays lit even locked: its brackets in the voice and its name at
   full, and once reachable or claimed its frame carries the bloom. */
.tile.legend.shut {
  --bracket: var(--op-red-idle);
}

.tile.legend.shut .tile-name,
.tile.legend.shut .glyph {
  color: var(--op-text);
}

.tile.legend.op-frame {
  --aug-border-all: 2px;
}

/* THE PICK: the brightest stroke and the bloom (`.op-lift`, which follows the
   cut) -- selection is the one thing that earns both. On a readout the
   brackets take the voice instead, and its name comes up to full. */
.tile.op-frame.is-picked,
.tile.op-frame.is-picked:hover {
  --aug-border-bg: var(--op-red-hi);
  --aug-border-all: 2px;
}

.tile.shut.is-picked {
  --bracket: var(--op-red-hi);
}

.tile.shut.is-picked .tile-name {
  color: var(--op-text);
}

/* ── the roots ───────────────────────────────────────────────────────────── */
/* Pinned to the foot of the region, so a tree taller than the screen still
   says whose column is whose while its crown is scrolled into view. */
.roots {
  position: sticky;
  bottom: 0;
  z-index: 4;
  flex: none;
  height: var(--roots-h);
}

.gate-pad {
  position: sticky;
  left: 0;
  z-index: 3;
}

/* Only while the tree slides under them do the roots and gates take a ground
   -- a ground under type (rule 1), opaque so nothing ghosts through it, and
   edged with the house hairline: a frozen pane, for the rare tree bigger than
   the screen. */
.scroller.slid .roots,
.scroller.slid .gate {
  background: rgb(var(--op-plate-rgb));
}

.scroller.slid .roots {
  box-shadow: 0 -1px 0 var(--op-line);
}

/* THE TRUNK'S ROOT: its emblem and name, the work that feeds it, its rank
   drawn and said, and its step toward the next. */
.trunk {
  position: relative;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  gap: 4px;
  min-width: 0;
  margin: 0 3px;
  padding: 10px 4px 4px 8px;
  border-left: 2px solid var(--op-red-idle);
}

/* The wire from the root up into the first node. */
.wire.lead {
  position: absolute;
  top: 0;
  left: calc(50% - 1px);
  height: 8px;
  min-height: 0;
  flex: none;
}

.trunk-top {
  display: flex;
  align-items: center;
  gap: 4px;
  min-width: 0;
}

.emblem {
  flex: none;
  width: 16px;
  height: 16px;
  fill: none;
  stroke: currentcolor;
  stroke-width: 1.8;
  stroke-linecap: round;
  stroke-linejoin: round;
  color: var(--op-red);
}

.trunk-name {
  font: 700 var(--op-fs-lead) / 1 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  text-transform: uppercase;
  color: var(--op-text);
}

.trunk-feed {
  font: 400 var(--op-fs-label) / 1.2 var(--op-font-body);
  color: var(--op-text-dim);
}

/* THE RANK, DRAWN AND FILLING: one cell per node the trunk declares, lit as
   far as the work has reached, and the next one filling toward its rank by
   the step's own `xp/need` -- the rank and the gauge in one stroke, the way
   the game draws a perk's levels. The two lines under it say both numbers
   (rule 8). */
.segs {
  display: flex;
  gap: 3px;
  height: 5px;
  margin-top: 1px;
}

.seg {
  position: relative;
  flex: 1 1 0;
  min-width: 0;
  overflow: hidden;
  background: var(--op-line);
}

.seg.on {
  background: var(--op-red-idle);
}

.seg-fill {
  position: absolute;
  top: 0;
  bottom: 0;
  left: 0;
  background: var(--op-red-idle);
  transition: width var(--op-dur) var(--op-ease);
}

.trunk-rank {
  color: var(--op-red-text);
}

/* THE APEX'S ROOT is the one framed root: an enclosure (the bay's two
   corners, and the interlace, rule 9) with its stroke at the full voice, and
   the word that says what it is. */
.trunk.apex {
  border-left: 0;
  padding-left: 9px;
  --aug-tr: var(--op-cut-md);
  --aug-bl: var(--op-cut-md);
  --aug-border-bg: var(--op-red);
  background: var(--op-plate);
}

.trunk.apex .emblem,
.trunk.apex .trunk-name {
  color: var(--op-red-hi);
}

/* The word rides in the root's top margin like a tab over the name -- clear
   of the chamfer on the right and of the lead wire in the middle -- so the
   fixer's name keeps the whole line in either language. */
.apex-chip {
  position: absolute;
  top: 1px;
  left: 9px;
  color: var(--op-red);
}

/* ── the chrome band ─────────────────────────────────────────────────────── */
.band {
  flex: none;
  display: grid;
  grid-template-columns: 188px minmax(0, 1fr) minmax(0, 1.25fr) minmax(0, 0.85fr);
  column-gap: var(--op-space-4);
  padding-top: 8px;
  border-top: 1px solid var(--op-line);
}

.band-title {
  display: flex;
  flex-direction: column;
  gap: 3px;
  min-width: 0;
}

.band-name {
  font-size: var(--op-fs-meta);
  color: var(--op-text);
}

.band-at {
  color: var(--op-red-text);
}

.stat,
.track {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 0;
  padding-left: var(--op-space-3);
  border-left: 1px solid var(--op-line);
}

.stat-head {
  display: flex;
  align-items: baseline;
  gap: var(--op-space-2);
  min-width: 0;
}

.stat-now {
  flex: none;
  font: 700 var(--op-fs-title) / 1 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  font-variant-numeric: tabular-nums;
  color: var(--op-text);
  white-space: nowrap;
}

.stat-step {
  color: var(--op-red-text);
}

.stat-ends,
.track-head {
  display: flex;
  justify-content: space-between;
  gap: var(--op-space-2);
  white-space: nowrap;
}

/* THE LEVEL TRACK: one cell per level, 1..cap, lit to the character's level.
   The cells are one repeating gradient and the lit run is the same gradient
   clipped, so a cell is the same cell in both and no level is an element. */
.track-bar {
  --cell: calc(100% / var(--cells));
  position: relative;
  height: 10px;
  margin-top: 3px;
  background: repeating-linear-gradient(
    90deg,
    var(--op-line) 0 calc(var(--cell) - 2px),
    transparent calc(var(--cell) - 2px) var(--cell)
  );
}

.track-lit {
  position: absolute;
  inset: 0;
  background: repeating-linear-gradient(
    90deg,
    var(--op-red-idle) 0 calc(var(--cell) - 2px),
    transparent calc(var(--cell) - 2px) var(--cell)
  );
}

.track-now,
.track-cue {
  position: absolute;
  top: -3px;
  bottom: -3px;
  box-sizing: border-box;
  width: calc(var(--cell) - 2px);
}

.track-now {
  background: var(--op-red);
  box-shadow: 0 0 6px var(--op-red-glow);
}

.track-cue {
  border: 1px solid var(--op-red-hi);
}

.track-ends {
  position: relative;
  height: 10px;
}

.track-start,
.track-end,
.track-here {
  position: absolute;
  top: 0;
}

.track-start {
  left: 0;
}

.track-end {
  right: 0;
}

.track-here {
  color: var(--op-red-hi);
}

/* ── the detail column ───────────────────────────────────────────────────── */
/* A column, not a box: its edge is a 1px rule (rule 2). It scrolls only if a
   locale's sentence outgrows it, never at the shipped strings. */
.side {
  grid-area: side;
  display: flex;
  flex-direction: column;
  gap: 10px;
  min-width: 0;
  min-height: 0;
  padding-left: var(--op-space-4);
  border-left: 1px solid var(--op-line);
  overflow-x: hidden;
  overflow-y: auto;
}

.side::-webkit-scrollbar {
  width: 4px;
}

.side::-webkit-scrollbar-thumb {
  background: var(--op-red-idle);
}

/* The picked node's plate: an enclosure holding its picture, so it takes the
   bay's two corners and the interlace (rule 9), and its stroke says the state. */
.plate {
  flex: none;
  display: flex;
  align-items: center;
  gap: var(--op-space-3);
  height: 80px;
  padding: 0 var(--op-space-4);
  --aug-tr: var(--op-cut-md);
  --aug-bl: var(--op-cut-md);
  background: var(--op-plate);
  color: var(--op-red);
}

.plate.is-unlocked {
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2px;
  background: var(--op-plate-lit);
  color: var(--op-red-hi);
}

.plate.is-locked {
  --aug-border-bg: var(--op-line);
  color: var(--op-text-faint);
}

.plate-glyph {
  flex: none;
  width: 46px;
  height: 46px;
  fill: none;
  stroke: currentcolor;
  stroke-width: 1.4;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.plate-read {
  display: flex;
  flex-direction: column;
  gap: 5px;
  min-width: 0;
}

.stamp {
  font: 700 var(--op-fs-title) / 1 var(--op-font-display);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
}

.plate.is-locked .stamp {
  color: var(--op-text-dim);
}

.plate-cost {
  color: var(--op-red-text);
}

.detail-name {
  flex: none;
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  overflow: hidden;
  font: 700 var(--op-fs-head) / 1.05 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  text-transform: uppercase;
  color: var(--op-text);
}

.desc {
  margin: 0;
  font-size: 13px;
  line-height: 1.4;
  color: var(--op-text);
}

/* The perk's value, lit where the sentence says it: the one number the node
   is about. */
.hl {
  color: var(--op-red-hi);
  font-weight: 600;
}

.facts {
  flex: none;
  margin: 0;
  display: flex;
  flex-direction: column;
}

.fact {
  display: grid;
  grid-template-columns: 56px minmax(0, 1fr);
  align-items: baseline;
  gap: 6px;
  padding: 4px 0;
  border-top: 1px solid var(--op-line);
}

.fact:last-child {
  border-bottom: 1px solid var(--op-line);
}

.fact dt {
  margin: 0;
}

/* The value role at a closer tracking: a fact is a short phrase in a narrow
   column, and the French ones are the longest. */
.fact dd {
  margin: 0;
  letter-spacing: var(--op-track-lead);
  color: var(--op-text);
}

.fact dd.hl {
  color: var(--op-red-hi);
}

/* What can be done, at the column's foot: the server's sentence for the state
   and, only on a node the server called `available`, the one control. */
.act {
  margin-top: auto;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-3);
}

.verdict {
  margin: 0;
  color: var(--op-text-dim);
}

.verdict.available {
  color: var(--op-red-text);
}

.verdict.unlocked {
  color: var(--op-red-hi);
}

.buy {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: var(--op-space-2);
  min-width: 0;
  height: 40px;
  padding: 0 var(--op-space-4);
  font: 700 var(--op-fs-lead) / 1 var(--op-font-display);
  letter-spacing: var(--op-track-label);
  text-transform: uppercase;
  color: var(--op-red-hi);
  cursor: pointer;
  appearance: none;
  -webkit-appearance: none;
  border: 0;
}

.buy-mouse,
.cap-mouse,
.quick-glyph {
  flex: none;
  fill: none;
  stroke: currentcolor;
  stroke-width: 1.8;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.buy-mouse {
  width: 18px;
  height: 18px;
}

.ready-head {
  padding-top: var(--op-space-2);
  border-top: 1px solid var(--op-line);
}

.ready {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.ready .op-copy {
  margin: 0;
}

.quick {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  min-width: 0;
  padding: 6px var(--op-space-3) 6px var(--op-space-2);
  text-align: left;
  cursor: pointer;
  font: inherit;
}

.quick-glyph {
  width: 18px;
  height: 18px;
  color: var(--op-red);
}

.quick-text {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  gap: 3px;
  min-width: 0;
}

.quick-name {
  font: 700 13px / 1.1 var(--op-font-display);
  letter-spacing: var(--op-track-lead);
  text-transform: uppercase;
  color: var(--op-text);
}

/* ── the foot ────────────────────────────────────────────────────────────── */
.foot {
  grid-area: foot;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--op-space-5);
  min-width: 0;
  padding-top: 6px;
  border-top: 1px solid var(--op-line);
}

.ledger {
  flex: 1 1 auto;
  min-width: 0;
}

/* The ledger's newest word, one line. A LEVEL OR A CLAIMED NODE is the news a
   player looks up for (it earned the voice); work credited settles at dim. */
.gain {
  display: block;
  color: var(--op-text-dim);
}

.gain.hot {
  color: var(--op-red);
}

.hints {
  flex: none;
  display: flex;
  align-items: center;
  gap: var(--op-space-5);
}

.hint {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  color: var(--op-text);
}

/* A hint whose control is not on screen right now says so by stepping down. */
.hint.idle {
  color: var(--op-text-dim);
}

/* A keycap depicts a physical key, so it keeps the house frame at cap size;
   the chamfer lives top-right, so the right side pays for it. */
.cap {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  box-sizing: border-box;
  min-width: 22px;
  height: 20px;
  padding: 0 5px;
  padding-right: calc(5px + var(--op-cut-sm));
  font: 700 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: 0.04em;
  color: var(--op-red);
}

.hint.idle .cap {
  color: var(--op-text-dim);
  --aug-border-bg: var(--op-line);
}

.cap-mouse {
  width: 13px;
  height: 13px;
}
</style>
