import { bool, list, num, own, records, table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'

/**
 * THE DOOR PANEL'S MODEL -- ox_doorlock's `web/src/store` and `utils/convertData`,
 * typed, and coerced at the wire.
 *
 * ox keeps one zustand store for the door being edited (`StoreState`) and one for the
 * table (`DoorColumn[]`), converts a door's `groups` map into rows for the form and back
 * on submit (`convertData`, `Submit.handleSubmit`). The same three steps live here:
 * `readDetail` is convertData, `toPayload` is handleSubmit, `emptyDraft` is ox's
 * `defaultState`. Everything Lua sends goes through `records()` / `table()` / `text()`
 * first -- an empty Lua table arrives as `{}`, and a sequence with a hole as
 * `[a, null, b]` -- and every closed lookup reads OWN keys only (`own()`).
 *
 * NOTHING HERE IS TRUSTED. `toPayload` builds an INTENT; the server re-validates every
 * field (`modules/doorlock/shared/access.lua`, `Normalize`) and may refuse the whole door.
 */

/** ox's settings tabs, in ox's order. `back` is ox's first tab, which returns to the table. */
export const TABS = ['general', 'characters', 'groups', 'items', 'lockpick', 'sound'] as const
export type Tab = (typeof TABS)[number]

/** Rows of the table per page. ox shows eight in a 500px window; this panel is taller. */
export const PAGE_SIZE = 10

/** What the server says this staff member may do. A button it refuses is greyed. */
export interface Access {
  save: boolean
  remove: boolean
  lock: boolean
  key: boolean
  teleport: boolean
}

/** The bounds and defaults Lua read from `config/doorlock.lua`. */
export interface Defaults {
  maxDistance: number
  maxReach: number
  autolockMax: number
  nameMax: number
  passcodeMax: number
  steps: Step[]
  stepsMax: number
  groupsMax: number
  itemsMax: number
  charactersMax: number
}

/** One row of ox's door table. `distance` is -1 for a door in another bucket. */
export interface Row {
  id: number
  name: string
  state: number
  distance: number
  double: boolean
  seeded: boolean
}

export interface Point {
  x: number
  y: number
  z: number
}

/** One native door: ox's `model` + `coords`, here its opaque id + coords. */
export interface Leaf {
  native: string
  coords: Point | null
}

/** ox's skill-check step: a named difficulty, or a custom ring. */
export type Step = string | { areaSize: number; speedMultiplier: number }

export interface GroupRow {
  name: string
  grade: number
}

export interface ItemRow {
  name: string
  metadata: string
  remove: boolean
}

/** ox's `StoreState`, plus what this server adds (`onDuty`) and keeps (the code). */
export interface Draft {
  id: number | null
  name: string
  /** What the staff member TYPED. The code itself never comes back from the server. */
  passcode: string
  hasPasscode: boolean
  clearPasscode: boolean
  autolock: number
  maxDistance: number
  state: boolean
  double: boolean
  auto: boolean
  lockpick: boolean
  hideUi: boolean
  holdOpen: boolean
  onDuty: boolean
  doors: Leaf[]
  coords: Point | null
  characters: string[]
  groups: GroupRow[]
  items: ItemRow[]
  steps: Step[]
  lockSound: string
  unlockSound: string
}

/** The fields ox's "Copy settings" carries: everything but the door itself. */
export type Settings = Omit<Draft, 'id' | 'name' | 'doors' | 'coords' | 'double' | 'hasPasscode'>

export function readAccess(value: unknown): Access {
  const raw = table(value)
  return {
    save: bool(raw.save),
    remove: bool(raw.remove),
    lock: bool(raw.lock),
    key: bool(raw.key),
    teleport: bool(raw.teleport)
  }
}

export function readStep(value: unknown): Step | null {
  if (typeof value === 'string' && value !== '') return value
  const raw = table(value)
  const area = num(raw.areaSize, NaN)
  const speed = num(raw.speedMultiplier, NaN)
  if (!Number.isFinite(area) || !Number.isFinite(speed)) return null
  return { areaSize: area, speedMultiplier: speed }
}

function readSteps(value: unknown): Step[] {
  const out: Step[] = []
  for (const entry of list(value)) {
    const step = readStep(entry)
    if (step !== null) out.push(step)
  }
  return out
}

export function readDefaults(value: unknown): Defaults {
  const raw = table(value)
  return {
    maxDistance: num(raw.maxDistance, 2),
    maxReach: num(raw.maxReach, 8),
    autolockMax: num(raw.autolockMax, 3600),
    nameMax: num(raw.nameMax, 64),
    passcodeMax: num(raw.passcodeMax, 32),
    steps: readSteps(raw.steps),
    stepsMax: num(raw.stepsMax, 10),
    groupsMax: num(raw.groupsMax, 16),
    itemsMax: num(raw.itemsMax, 8),
    charactersMax: num(raw.charactersMax, 32)
  }
}

/** A list of plain strings: every non-string element dropped. */
export function readStrings(value: unknown): string[] {
  return list(value).filter((entry): entry is string => typeof entry === 'string')
}

export function readRows(value: unknown): Row[] {
  return records(value)
    .map((row) => ({
      id: num(row.id, -1),
      name: text(row.name),
      state: num(row.state, 1) === 0 ? 0 : 1,
      distance: num(row.distance, -1),
      double: bool(row.double),
      seeded: bool(row.seeded)
    }))
    .filter((row) => row.id > 0)
}

function readPoint(value: unknown): Point | null {
  const raw = table(value)
  const x = num(raw.x, NaN)
  const y = num(raw.y, NaN)
  const z = num(raw.z, NaN)
  if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(z)) return null
  return { x, y, z }
}

export function readLeaves(value: unknown): Leaf[] {
  return records(value)
    .map((leaf) => ({ native: text(leaf.native), coords: readPoint(leaf.coords) }))
    .filter((leaf) => leaf.native !== '')
    .slice(0, 2)
}

/** ox's `defaultState`: the form a new door starts from. */
export function emptyDraft(defaults: Defaults): Draft {
  return {
    id: null,
    name: '',
    passcode: '',
    hasPasscode: false,
    clearPasscode: false,
    autolock: 0,
    maxDistance: defaults.maxDistance,
    state: true,
    double: false,
    auto: false,
    lockpick: false,
    hideUi: false,
    holdOpen: false,
    onDuty: false,
    doors: [],
    coords: null,
    characters: [''],
    groups: [{ name: '', grade: 0 }],
    items: [{ name: '', metadata: '', remove: false }],
    steps: [],
    lockSound: '',
    unlockSound: ''
  }
}

/** A new door the eye's "Manage door" already took a leaf for. */
export function prefill(defaults: Defaults, value: unknown): Draft {
  const draft = emptyDraft(defaults)
  const raw = table(value)
  draft.doors = readLeaves(raw.doors)
  draft.double = draft.doors.length === 2
  draft.coords = readPoint(raw.coords)
  return draft
}

/**
 * ox's `convertData`: a stored door into the form. `groups` arrives as ox's map of name
 * to grade and leaves as rows; every list keeps one blank row, as ox's form does.
 */
export function readDetail(defaults: Defaults, value: unknown): Draft {
  const raw = table(value)
  const draft = emptyDraft(defaults)
  draft.id = num(raw.id, -1) > 0 ? num(raw.id) : null
  draft.name = text(raw.name)
  // Staff who may edit the door are sent the code itself, to read it here;
  // anybody else gets only whether there is one.
  draft.passcode = text(raw.passcode)
  draft.hasPasscode = bool(raw.hasPasscode) || draft.passcode !== ''
  draft.autolock = num(raw.autolock, 0)
  draft.maxDistance = num(raw.maxDistance, defaults.maxDistance)
  draft.state = num(raw.state, 1) === 1
  draft.auto = bool(raw.auto)
  draft.lockpick = bool(raw.lockpick)
  draft.hideUi = bool(raw.hideUi)
  draft.holdOpen = bool(raw.holdOpen)
  draft.onDuty = bool(raw.onDuty)
  draft.coords = readPoint(raw.coords)
  const doors = readLeaves(raw.doors)
  const single = text(raw.native)
  draft.doors = doors.length > 0 ? doors : single !== '' ? [{ native: single, coords: draft.coords }] : []
  draft.double = draft.doors.length === 2
  const characters = list(raw.characters).map((entry) =>
    typeof entry === 'number' ? String(entry) : text(entry)
  )
  draft.characters = characters.length > 0 ? characters : ['']
  const groups: GroupRow[] = []
  const map = table(raw.groups)
  for (const name of Object.keys(map)) groups.push({ name, grade: num(own(map, name), 0) })
  groups.sort((a, b) => a.name.localeCompare(b.name))
  draft.groups = groups.length > 0 ? groups : [{ name: '', grade: 0 }]
  const items = records(raw.items).map((item) => ({
    name: text(item.name),
    metadata: text(item.metadata),
    remove: bool(item.remove)
  }))
  draft.items = items.length > 0 ? items : [{ name: '', metadata: '', remove: false }]
  draft.steps = readSteps(raw.lockpickDifficulty)
  draft.lockSound = text(raw.lockSound)
  draft.unlockSound = text(raw.unlockSound)
  return draft
}

/** A deep copy of the settings ox's "Copy settings" keeps. */
export function copySettings(draft: Draft): Settings {
  return {
    passcode: draft.passcode,
    clearPasscode: draft.clearPasscode,
    autolock: draft.autolock,
    maxDistance: draft.maxDistance,
    state: draft.state,
    auto: draft.auto,
    lockpick: draft.lockpick,
    hideUi: draft.hideUi,
    holdOpen: draft.holdOpen,
    onDuty: draft.onDuty,
    characters: [...draft.characters],
    groups: draft.groups.map((row) => ({ ...row })),
    items: draft.items.map((row) => ({ ...row })),
    steps: draft.steps.map((step) => (typeof step === 'string' ? step : { ...step })),
    lockSound: draft.lockSound,
    unlockSound: draft.unlockSound
  }
}

/** Whether the draft has the leaves its double switch asks for. */
export function hasLeaves(draft: Draft): boolean {
  return draft.doors.length === (draft.double ? 2 : 1)
}

/**
 * ox's `handleSubmit`: the form into the door the server stores. Blank rows dropped,
 * the groups rows back into ox's map shape (sent as rows; the server takes either),
 * a code the staff member did not type left out so the server keeps the one it has,
 * and an explicit '' when they asked for it to be cleared.
 */
export function toPayload(draft: Draft, defaults: Defaults): Payload {
  const door: Payload = {
    name: draft.name.trim() === '' ? undefined : draft.name.trim(),
    state: draft.state,
    maxDistance: draft.maxDistance > 0 ? draft.maxDistance : defaults.maxDistance,
    autolock: draft.autolock > 0 ? Math.floor(draft.autolock) : undefined,
    auto: draft.auto,
    lockpick: draft.lockpick,
    hideUi: draft.hideUi,
    holdOpen: draft.holdOpen,
    onDuty: draft.onDuty,
    doors: draft.doors.map((leaf) => ({
      native: leaf.native,
      coords: leaf.coords ?? draft.coords ?? undefined
    })),
    coords: draft.coords ?? undefined,
    characters: draft.characters.map((entry) => entry.trim()).filter((entry) => entry !== ''),
    groups: draft.groups
      .filter((row) => row.name.trim() !== '')
      .map((row) => ({ name: row.name.trim(), grade: Math.max(0, Math.floor(row.grade || 0)) })),
    items: draft.items
      .filter((row) => row.name.trim() !== '')
      .map((row) => ({
        name: row.name.trim(),
        metadata: row.metadata.trim() === '' ? undefined : row.metadata.trim(),
        remove: row.remove
      })),
    lockpickDifficulty: draft.steps.length > 0 ? draft.steps : undefined,
    lockSound: draft.lockSound === '' ? undefined : draft.lockSound,
    unlockSound: draft.unlockSound === '' ? undefined : draft.unlockSound
  }
  if (draft.clearPasscode) door.passcode = ''
  else if (draft.passcode !== '') door.passcode = draft.passcode
  return door
}

/** The label of a step: the locale key of a named one, or 'custom'. */
export function stepKey(step: Step): string {
  return typeof step === 'string' ? `doorlock.difficulty.${step}` : 'doorlock.ui.custom'
}

/** The verbs whose success sends the panel back to the table, as ox's navigate('/'). */
const BACK_TO_LIST: Record<string, boolean> = { save: true, remove: true }

export function returnsToList(verb: string): boolean {
  return own(BACK_TO_LIST, verb) === true
}

/**
 * Drops every `undefined` key, deeply. `toPayload` leaves a field out by setting it to
 * `undefined`, and what reaches Lua must not carry the key at all: a bridge that turned
 * it into `null` would hand the server a value where the form meant "nothing".
 */
export function prune(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(prune)
  if (value !== null && typeof value === 'object') {
    const out: Record<string, unknown> = {}
    for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
      if (child !== undefined) out[key] = prune(child)
    }
    return out
  }
  return value
}

/**
 * Every intent this page sends, spelt out. Lua wires each by its full name
 * (`modules/doorlock/client/panel.lua`), and a name built from a template here would be
 * one nothing could grep for on either side.
 */
export const INTENTS = {
  list: 'opx:doorlock:list',
  detail: 'opx:doorlock:detail',
  save: 'opx:doorlock:save',
  delete: 'opx:doorlock:delete',
  state: 'opx:doorlock:state',
  key: 'opx:doorlock:key',
  teleport: 'opx:doorlock:teleport',
  pick: 'opx:doorlock:pick',
  dismiss: 'opx:doorlock:dismiss'
} as const
export type Intent = keyof typeof INTENTS
