import { reactive, readonly } from 'vue'

/**
 * How much of a screen corner a transient surface is holding right now, in pixels
 * measured up from that corner's inset.
 *
 * THE OWNER: "pour le hud micro si prompt montrer alors fait en sorte que l'hud se
 * retrouve pas sous les prompt". Both default to the bottom-right corner, and the key
 * strip is drawn over the voice block whenever a prompt is up. The strip is the thing
 * being read at that moment, so it keeps its place and the voice block steps up by what
 * the strip holds; when the strip closes the hold is zero and the block comes back.
 *
 * Same shape as `ui.ts`: a module-scope `reactive`, no Pinia, and nothing here is
 * authoritative -- it is a measurement one module publishes and another reads.
 */
interface Corners {
  /** Height the open key strip takes in the bottom-right corner, or 0. */
  bottomRight: number
  /** How far up from the screen's bottom edge the vehicle dial reaches while it is up
      and sits over the middle of the screen, or 0. The hotbar peek, which is centred
      on the same edge, stands on top of it instead of over it. */
  bottomCenter: number
}

const state = reactive<Corners>({ bottomRight: 0, bottomCenter: 0 })

export const corners = readonly(state)

export function holdBottomRight(px: number): void {
  state.bottomRight = px > 0 && Number.isFinite(px) ? Math.round(px) : 0
}

export function holdBottomCenter(px: number): void {
  state.bottomCenter = px > 0 && Number.isFinite(px) ? Math.round(px) : 0
}
