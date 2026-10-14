/**
 * The wire between this page and Lua.
 *
 * INVARIANT -- THE PAGE SENDS INTENTS, NEVER FACTS.
 * Every payload leaving here is a request ("the player pressed use on slot 3"), never a
 * conclusion ("the player now has 4 medkits"). Lua re-derives all of it server-side and
 * the page is told the result. Nothing computed here is trusted by anything, including
 * this page: a value is only real once it has come back over a channel.
 */

/** A channel name. Always `opx:<module>:<verb>`, matching the Lua side exactly. */
export type Channel = string

/** Anything that survives the Lua <-> JSON boundary. */
export type Json = string | number | boolean | null | Json[] | { [key: string]: Json }
export type Payload = Record<string, unknown>

export type Handler = (payload: Payload) => void

/** The two globals the CEF surface is given. There is nothing else. */
export interface Open77Bridge {
  on(channel: Channel, handler: Handler): void
  emit(channel: Channel, payload: Payload): void
}

declare global {
  interface Window {
    Open77?: Open77Bridge
    /** Set by the dev shim only. Never present in game. See bridge/devshim.ts. */
    __OPX_DEV_SHIM__?: boolean
  }
}

/* -- Lua-shaped coercions ---------------------------------------------------------------
   An empty Lua table serialises to `{}`, not `[]`, so `value || []` keeps the object and
   the next `.map` throws inside a handler the bridge then swallows. Every list crossing
   the wire goes through `list()`, without exception. */

export function list<T = unknown>(value: unknown): T[] {
  return Array.isArray(value) ? (value as T[]) : []
}

export function text(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback
}

export function num(value: unknown, fallback = 0): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

export function bool(value: unknown, fallback = false): boolean {
  return typeof value === 'boolean' ? value : fallback
}

/** A Lua table used as a map; `{}` and a missing key are the same thing to us. */
export function table(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {}
}

/**
 * A list of RECORDS: `list()` plus `table()` on every element.
 *
 * `records()` only proves the outer value is an array. A Lua sequence with a hole
 * in it arrives as `[a, null, b]`, and the first `row.id` on the null throws halfway
 * through an apply -- after some fields are already written, so the view is left
 * half-updated (or, on an open, invisible while Lua believes it is up). Each element is
 * coerced in place rather than filtered out, so a row keeps its index: several views
 * address rows by the position Lua gave them.
 */
export function records(value: unknown): Payload[] {
  return list(value).map(table)
}

/**
 * `map[key]`, but only for the map's OWN keys.
 *
 * Every closed lookup table here is an object literal, and an object literal inherits
 * from `Object.prototype`: a Lua string of `"constructor"` or `"toString"` reads back a
 * FUNCTION instead of `undefined`, slips past the `?? fallback`, and the first string
 * method called on it throws in the middle of a render.
 */
export function own<T>(map: Record<string, T>, key: string): T | undefined {
  return Object.prototype.hasOwnProperty.call(map, key) ? map[key] : undefined
}
