import { computed, reactive, readonly } from 'vue'
import { table, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'

/**
 * Surface-wide state. Deliberately not Pinia.
 *
 * Pinia would be one more runtime in the bundle for a store with four
 * fields and no devtools to inspect it with -- the CEF has no extensions. A module
 * scope plus `reactive` is the same thing minus the ceremony, and it stays portable:
 * `reactive` and `computed` are the whole API and both exist in Vue 2.7.
 *
 * Nothing here is authoritative. Every field is the last thing LUA SAID, cached so
 * the render does not have to ask again. The page never writes a value it invented.
 */

/**
 * Which LAYER of the single surface a module draws on. There used to be two CEF pages
 * and this named them; there is one now, and these are stacking contexts inside it.
 *
 * The distinction still earns its keep: `overlay` never takes a pointer or the
 * keyboard, `modal` does. A module declaring the wrong one either cannot be clicked or
 * goes inert as soon as nothing holds focus.
 *
 * `notice` sits between `modal` and `cover`, and it holds the toasts. A toast is usually
 * the answer to something the player just did on a modal view, and on `overlay` a refusal
 * raised by a form or the join screen was drawn UNDER that view's scrim -- dimmed by half
 * exactly when it had to be read. It never takes a pointer.
 *
 * `cover` is the last, and it holds one thing: the loading cover, drawn OVER all of the
 * others while the game's own loading screen is up. It never takes a pointer either --
 * a load is not something the player drives.
 */
export type LayerName = 'overlay' | 'modal' | 'notice' | 'cover'

interface UiState {
  /**
   * Something on the interactive layer holds focus.
   *
   * With one surface this drives `pointer-events` on that layer: a full-screen
   * transparent div that accepts clicks while nothing is open is a player who cannot
   * shoot. Two pages got this for free by not existing.
   */
  focused: boolean
  /** `opx:locale:set`. Keys, never sentences -- see useLocale. */
  strings: Record<string, string>
  /** Whether a whole catalogue has landed. Until it has, a missing key is a key
      that has not ARRIVED yet rather than one that does not exist, and `useLocale`
      draws nothing for it instead of the raw key. */
  stringsReady: boolean
  /** Modules ModuleHost has unmounted after a throw. Shown in the diag overlay only. */
  failed: string[]
}

const state = reactive<UiState>({
  focused: false,
  strings: {},
  stringsReady: false,
  failed: []
})

/* The catalogue being received, swapped in whole when its last part lands. Parts used
   to be merged into the live dictionary as they arrived, so a language change emptied
   every label for the frames in between; and on a cold page every label that had not
   arrived yet painted as its raw key -- `hud.voice.state.idle` on the HUD. */
let incomingStrings: Record<string, string> | null = null

export const ui = readonly(state)

export const isFocused = computed(() => state.focused)

export function setFocused(focused: boolean): void {
  state.focused = focused
}

/**
 * Takes one PART of the dictionary. Lua sends the catalogue in parts because the whole
 * of it -- 1,533 keys, about 78 kB -- is well past the ~1,024 value nodes a single page
 * write carries, and a write past that is dropped by the host without a word. The
 * symptom when it happened was total: `useLocale` answers the key on a miss, so every
 * label on every surface rendered as its own raw key for the whole session.
 *
 * `first` clears what is held and `done` marks the last part -- the same flags
 * `modules/inventory` drains its item catalogue with. A payload carrying NEITHER flag
 * is treated as a whole catalogue in one part, which is what every older sender did.
 *
 * It still REPLACES rather than merges across a language change: Lua owns the player's
 * language and may change it mid-session, and merging would leave the previous
 * language's strings behind for any key the new one happens not to define. That is what
 * `first` is for -- it is the clear, moved from "every send" to "the send that starts a
 * catalogue".
 */
export function setStrings(payload: Payload): void {
  const incoming = table(payload.strings)
  const first = payload.first !== false
  // A payload with neither flag is a whole catalogue in one part, as before.
  const done = payload.done !== false
  if (first || incomingStrings === null) incomingStrings = {}
  for (const key of Object.keys(incoming)) incomingStrings[key] = text(incoming[key], key)
  if (!done) return
  state.strings = incomingStrings
  incomingStrings = null
  state.stringsReady = true
}

export function noteModuleFailure(id: string): void {
  if (!state.failed.includes(id)) state.failed.push(id)
}

export function clearModuleFailure(id: string): void {
  const at = state.failed.indexOf(id)
  if (at !== -1) state.failed.splice(at, 1)
}
