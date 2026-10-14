import { bool, list, num, table, text, records } from '@/bridge/types'

/**
 * The shapes Lua sends, parsed on arrival.
 *
 * Nothing below is a fact this page decided. A container is the server's copy as
 * of its last push; a catalogue entry is a row out of the data files both halves
 * load. The page draws them and reports what the player DID to them.
 *
 * Every list goes through `list()`: an empty Lua table serialises to `{}` and not
 * `[]`, so `payload.items || []` keeps the object and the next `.map` throws
 * inside a handler the bridge then swallows.
 */

/** Echoed on every emit. A payload carrying any other handle is a stale screen. */
export type Handle = string

export interface Stack {
  slot: number
  name: string
  count: number
  /** Trimmed by Lua when a container is too large to push whole. */
  metadata: Record<string, unknown>
}

export interface Container {
  id: number
  kind: string
  /** Lua's own title for a stash or a searched bag; empty for the plain kinds. */
  title: string
  slots: number
  maxWeight: number
  /** Grams, re-derived server-side. Never computed here. */
  weight: number
  /** Slot number to the stack in it. Sparse: an empty slot has no entry. */
  bySlot: Map<number, Stack>
}

export interface CatalogEntry {
  label: string
  description: string
  weight: number
  image: string
  usable: boolean
  stackable: boolean
  /**
   * Whether the server will let this be left on the ground. Advisory only --
   * `Actions.Drop` is the check -- and it is here so the menu stops offering a
   * row it is about to be refused for. Defaults TRUE, so an older server that
   * sends no such field behaves exactly as it did.
   */
  droppable: boolean
  category: string
  weapon: boolean
  ammo: boolean
}

export interface TabSpec {
  key: string
  label: string
  categories: string[]
  rest: boolean
}

export interface ScreenConfig {
  labels: Record<string, string>
  hotbar: string[]
  openKey: string
  drops: boolean
  /** Grams per unit of an item the catalogue no longer carries. */
  defaultWeight: number
}

export interface NearbyPlayer {
  id: number
  distance: number
  /** Which side of the giver they stand on: ahead, behind, left, right, or ''.
      Never a name: the server does not send one (the owner's decision). */
  side: string
}

export function readStack(value: unknown): Stack | null {
  const row = table(value)
  const slot = num(row.slot, 0)
  if (slot <= 0) return null
  return {
    slot,
    name: text(row.name),
    count: num(row.count, 0),
    metadata: table(row.metadata)
  }
}

export function readContainer(value: unknown): Container | null {
  const row = table(value)
  if (row.id === undefined) return null
  const bySlot = new Map<number, Stack>()
  for (const entry of list(row.items)) {
    const stack = readStack(entry)
    if (stack) bySlot.set(stack.slot, stack)
  }
  return {
    id: num(row.id, 0),
    kind: text(row.kind),
    title: text(row.title),
    slots: Math.max(0, num(row.slots, 0)),
    maxWeight: num(row.maxWeight, 0),
    weight: num(row.weight, 0),
    bySlot
  }
}

export function readCatalogEntry(value: unknown): CatalogEntry {
  const row = table(value)
  return {
    label: text(row.label),
    description: text(row.description),
    weight: num(row.weight, 0),
    image: text(row.image),
    usable: bool(row.usable),
    stackable: bool(row.stackable, true),
    droppable: bool(row.droppable, true),
    category: text(row.category, 'misc'),
    weapon: bool(row.weapon),
    ammo: bool(row.ammo)
  }
}

export function readConfig(value: unknown): ScreenConfig {
  const row = table(value)
  const labels: Record<string, string> = {}
  const incoming = table(row.labels)
  for (const key of Object.keys(incoming)) {
    if (key !== 'tabs') labels[key] = text(incoming[key], key)
  }
  return {
    labels,
    hotbar: list(incoming.hotbar ?? row.hotbar).map((key) => text(key)),
    openKey: text(row.openKey),
    drops: bool(row.drops),
    defaultWeight: num(row.defaultWeight, 0)
  }
}

export function readTabs(value: unknown): TabSpec[] {
  const incoming = table(value)
  return records(incoming.tabs).map((tab) => ({
    key: text(tab.key),
    label: text(tab.label),
    categories: list(tab.categories).map((name) => text(name)),
    rest: bool(tab.rest)
  }))
}

export function readNearby(value: unknown): NearbyPlayer[] {
  return records(value)
    .map((row) => ({ id: num(row.id, 0), distance: num(row.distance, 0), side: text(row.side) }))
    .filter((row) => row.id > 0)
}
