import { createApp } from 'vue'
import type { Component } from 'vue'
import { emit, handshake, subscribe } from '@/bridge/channel'
import { installDevShimIfMissing } from '@/bridge/devshim'
import { installDiagnostics, report } from '@/bridge/diag'
import { configureFocus } from '@/bridge/focus'
import { configureRpc } from '@/bridge/rpc'
import { setStrings } from '@/stores/ui'
import { applyLoading } from '@/stores/loading'
import { applyTheme } from '@/design-system/theme'
import '@/design-system/fonts.css'
import '@/design-system/tokens.css'
import '@/design-system/shapes.css'
import '@/design-system/surface.css'

/**
 * The one `createApp`, and everything that has to happen around it in order.
 *
 * There were two of these, one per CEF page. There is one page now, and `name` is what
 * is left of that: an identity for diagnostics and for the prefix on rpc refs, not a
 * choice of surface.
 *
 * The order below is not arbitrary:
 *  1. the dev shim, so a browser has a bridge before anything asks for one;
 *  2. diagnostics, so step 3 onwards has somewhere to report to;
 *  3. rpc and focus identity, so refs are prefixed before the first request;
 *  4. mount;
 *  5. `opx:ready` LAST. Lua takes it as permission to start pushing state, and a
 *     payload arriving before the channels are bound is a payload that is simply lost.
 */
export interface SurfaceOptions {
  /** Identity for diagnostics and rpc refs -- not a layer. */
  name: string
  root: Component
  rootProps?: Record<string, unknown>
  /**
   * Whether `acquireFocus` is honoured at all. True here: the page as a whole can take
   * focus, and which modules may ask is now a property of the LAYER they register on.
   */
  allowFocus: boolean
}

export function createSurface(options: SurfaceOptions): void {
  const { name, root, rootProps, allowFocus } = options

  const shimmed = installDevShimIfMissing(name)
  installDiagnostics(name)
  configureRpc(name)
  configureFocus(name, allowFocus)

  // Lua owns the player's language and may change it mid-session. Bound at boot and
  // never released: there is no moment in the session where a locale change is
  // uninteresting.
  subscribe('opx:locale:set', setStrings)

  // THE THEME IS NOT A MODULE, and that is why it is bound here beside the
  // catalogue rather than in `boot/registry.ts`. It draws nothing, owns no layer
  // and has no component: it is a set of custom properties on the document root,
  // which is above every module and outlives all of them. Binding it in a module
  // would also tie the whole surface's palette to that module not having thrown.
  //
  // Bound BEFORE the mount, so the first payload cannot arrive with nowhere to
  // go, and the properties are written before the first module paints if Lua
  // already has the answer in hand.
  subscribe('opx:theme:set', applyTheme)

  // The other half of the handshake the rest of the surface uses: Lua wires
  // `opx:<module>:ready` for every declared module when it builds the page, and
  // holds what arrives on one until that module registers. `emit` queues this
  // behind the handshake below and it goes out in the same tick.
  //
  // WITHOUT IT NOTHING IS EVER SENT. `lib/client/surface.lua` drops rather than
  // queues, so the theme cannot simply be pushed at the page and hoped for: the
  // page has to say it exists, exactly as the HUD, the chat and the inventory do.
  emit('opx:theme:ready', {})

  // THE GAME'S OWN LOADING SCREEN, bound here for the reason the theme is: what it
  // decides -- whether the HUD-like views are on screen at all -- is above every module,
  // and a binding inside the cover would let a throw in the cover strand them hidden for
  // the session. `modules/loading` answers the ready with whatever it last decided, so a
  // page that mounts in the middle of a load comes up already knowing.
  subscribe('opx:loading:state', applyLoading)
  emit('opx:loading:ready', {})

  const app = createApp(root, rootProps)

  // The last line of defence, below ModuleHost. Reaching this means something threw
  // outside every module boundary, and the app is already coming down; the report is
  // the only thing that will survive it.
  app.config.errorHandler = (error, _instance, info) => {
    report(error, `app ${name} [${info}]`)
  }

  const mount = document.getElementById('app')
  if (!mount) {
    report('no #app element in the document', `boot ${name}`)
    return
  }
  app.mount(mount)

  if (shimmed) document.documentElement.classList.add('opx-dev-shim')

  // `opx:ready`, not `opx:ui:ready`. `lib/client/surface.lua` owns this handshake
  // and wires it as `<surface id>:ready`; it sets `surface.ready` from that channel
  // and nothing else, and `OPX.Surface.Send` refuses everything until it is set.
  // Emitting any other name leaves the surface permanently unready -- silently,
  // because a refused send is a `false` return nobody reads.
  //
  // It also RELEASES the page: every emit a module made from `onMounted` -- and each
  // of the five `opx:<module>:ready` signals is one -- was held by channel.ts until
  // this line, because Lua drops its answer to anything that arrives before the
  // handshake. They go out now, in the order they were made.
  handshake('opx:ready', { surface: name })
}
