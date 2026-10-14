import { report } from '@/bridge/diag'
import { own } from '@/bridge/types'
import type { Payload } from '@/bridge/types'

/**
 * The operator's theme, written onto the document root as custom properties.
 *
 * WHY PROPERTIES AND NOT A STYLESHEET. `tokens.css` is already the one place a
 * value is decided, and every rung, ground, chamfer and tilt in the runtime reads
 * it through `var()`. Overriding those on `:root` is therefore the whole of the
 * mechanism: one write per value, the cascade does the rest, and nothing is
 * rebuilt, re-parsed or re-fetched. A second stylesheet, a `<style>` element or a
 * class per theme would each have needed the same list of values and a way to
 * keep it in step with this one.
 *
 * NOTHING THAT ARRIVES HERE IS CSS. The wire carries numbers only -- a colour is
 * three integers, a chamfer is a count of pixels -- and this file is what turns
 * them into `rgb(...)`, `px` and `deg`. That is not defensive dressing over a
 * string API: there is no string API. An operator's accent is parsed out of
 * `#RRGGBB` in Lua and travels as its channels, so no text an operator typed ever
 * reaches a stylesheet, and a payload cannot carry a declaration, a `}` or a
 * second property however it was produced.
 *
 * THE BOUNDS BELOW EXIST TWICE, here and in `modules/theme/shared/palette.lua`.
 * That is deliberate and it is the house rule rather than an oversight: the page
 * trusts nothing it is told, including by its own server, and `bridge/types.ts`
 * says so for every other payload on this surface. The Lua copy is what tells an
 * operator their value was out of range; this copy is what makes it impossible
 * for an out-of-range value to be applied.
 *
 * AN ABSENT KEY MEANS THE STYLESHEET WINS. Applying a theme clears every property
 * this file knows about first and then writes what it was given, so a server that
 * configures only a tilt gets the shipped ladder with a different tilt, and a
 * server that configures nothing at all gets exactly what `tokens.css` says. That
 * is the property that keeps an unconfigured server byte-identical to the one
 * that shipped, and it is why there are no defaults in this file.
 */

type Kind = 'rgb' | 'number' | 'px' | 'deg'

interface Knob {
  /** The custom property on `:root`. */
  property: string
  kind: Kind
  /** Inclusive, for everything but `rgb`, whose bound is always a byte. */
  min?: number
  max?: number
}

/**
 * Every property a theme may touch, and the only ones. A key that is not in here
 * is dropped: the map IS the allowlist, so adding a themeable value is one entry
 * and there is no path that writes a property nobody named.
 */
const KNOBS: Record<string, Knob> = {
  accent: { property: '--op-red-rgb', kind: 'rgb' },
  idle: { property: '--op-red-idle-rgb', kind: 'rgb' },
  deep: { property: '--op-red-deep-rgb', kind: 'rgb' },
  hi: { property: '--op-red-hi-rgb', kind: 'rgb' },
  text: { property: '--op-red-text-rgb', kind: 'rgb' },
  alarm: { property: '--op-alarm-rgb', kind: 'rgb' },
  plate: { property: '--op-plate-rgb', kind: 'rgb' },
  plateLit: { property: '--op-plate-lit-rgb', kind: 'rgb' },

  plateAlpha: { property: '--op-plate-a', kind: 'number', min: 0.2, max: 0.98 },
  plateQuietAlpha: { property: '--op-plate-quiet-a', kind: 'number', min: 0, max: 0.98 },
  plateLitAlpha: { property: '--op-plate-lit-a', kind: 'number', min: 0.2, max: 1 },
  interlaceAlpha: { property: '--op-interlace-a', kind: 'number', min: 0, max: 0.15 },

  tiltDeg: { property: '--op-tilt', kind: 'deg', min: 0, max: 15 },
  cutSm: { property: '--op-cut-sm', kind: 'px', min: 1, max: 24 },
  cutMd: { property: '--op-cut-md', kind: 'px', min: 1, max: 48 },
  cutLg: { property: '--op-cut-lg', kind: 'px', min: 1, max: 80 }
}

function clamp(value: number, low: number, high: number): number {
  return value < low ? low : value > high ? high : value
}

/** A finite number, or null. `num()` in bridge/types coerces to a fallback; here
 *  the difference between "absent" and "zero" is the whole decision. */
function finite(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

/**
 * The CSS text for one knob, or null when the value cannot be read as one.
 *
 * An rgb triple is rounded to bytes rather than rejected for being fractional:
 * Lua rounds already, and a channel arriving as 58.9999 after a JSON round trip
 * is the same colour, not a malformed one.
 */
function render(knob: Knob, value: unknown): string | null {
  if (knob.kind === 'rgb') {
    if (!Array.isArray(value) || value.length !== 3) return null
    const channels: number[] = []
    for (const raw of value) {
      const component = finite(raw)
      if (component === null) return null
      channels.push(Math.round(clamp(component, 0, 255)))
    }
    return channels.join(', ')
  }

  const number = finite(value)
  if (number === null) return null
  const held = clamp(number, knob.min ?? 0, knob.max ?? 1)
  if (knob.kind === 'px') return `${Math.round(held)}px`
  if (knob.kind === 'deg') return `${held}deg`
  return String(held)
}

/**
 * Applies a theme payload, replacing whatever the last one set.
 *
 * Exported for the same reason the store's setters are: `createSurface` binds it
 * to the channel, and nothing else calls it.
 */
export function applyTheme(payload: Payload): void {
  const root = document.documentElement
  if (!root) return

  // Cleared first, so this is idempotent and a key dropped from a later payload
  // goes back to the stylesheet rather than lingering from the previous one.
  for (const knob of Object.values(KNOBS)) root.style.removeProperty(knob.property)

  const refused: string[] = []
  for (const key of Object.keys(payload)) {
    const knob = own(KNOBS, key)
    if (!knob) {
      refused.push(key)
      continue
    }
    const text = render(knob, payload[key])
    if (text === null) {
      refused.push(key)
      continue
    }
    root.style.setProperty(knob.property, text)
  }

  // One line for the lot. This can only fire when the page and the server are
  // built from different versions of the resource, and then it fires for
  // everyone at once -- so it is worth the journal line and not worth one per
  // key. `report` reaches the SERVER log through the diagnostics relay, which is
  // the only place an operator can actually read it.
  if (refused.length > 0) {
    report(`theme keys refused: ${refused.join(' ')}`, 'theme')
  }
}
