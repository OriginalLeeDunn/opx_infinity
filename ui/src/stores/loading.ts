import { computed, reactive, readonly } from 'vue'
import { bool, num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'

/**
 * The game's own loading screen, as `modules/loading` last described it.
 *
 * BOUND AT THE SURFACE, NOT IN A VIEW. `hide` decides whether the HUD-like views are on
 * screen at all, and if it were held by the cover component a throw in the cover would
 * strand it: ModuleHost unmounts the cover, the subscription goes with it, and a `hide`
 * that arrived true stays true for the session -- no gauges, no key strip, no toasts,
 * and nothing anywhere saying why. So `createSurface` subscribes this the way it does the
 * theme and the catalogue, and the cover only READS it.
 *
 * Nothing here is decided on the page. When the cover goes up, whether there is a film
 * and what fraction to draw are all Lua's answer; the one rule the page adds is in the
 * cover itself -- it never draws "done".
 */
interface LoadingState {
  /** The HUD-like views step aside. True for exactly as long as the native load is up. */
  hide: boolean
  /** The OPX cover is drawn over the native screen. */
  cover: boolean
  /** The film behind the cover, or the poster alone. */
  video: boolean
  /** The server's own name for the bay, and the line under it; '' keeps the cover's. */
  name: string
  subtitle: string
  /** `unknown` or `fastTravel` -- the join kinds never reach a cover. */
  kind: string
  progressKnown: boolean
  /** 0..1, and it may go backwards: the platform says so, and it is drawn as said. */
  progress: number
}

const state = reactive<LoadingState>({
  hide: false,
  cover: false,
  video: true,
  name: '',
  subtitle: '',
  kind: 'unknown',
  progressKnown: false,
  progress: 0
})

export const loading = readonly(state)

export const isLoadingHidden = computed(() => state.hide)

/** `opx:loading:state`. Every field is read through the bridge's own coercions. */
export function applyLoading(payload: Payload): void {
  state.hide = bool(payload.hide)
  state.cover = bool(payload.cover)
  state.video = bool(payload.video, true)
  state.name = text(payload.name).slice(0, 32)
  state.subtitle = text(payload.subtitle).slice(0, 32)
  state.kind = text(payload.kind, 'unknown')
  state.progressKnown = bool(payload.progressKnown)
  const fraction = num(payload.progress)
  state.progress = Number.isFinite(fraction) ? Math.min(1, Math.max(0, fraction)) : 0
}
