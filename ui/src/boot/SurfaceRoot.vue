<script setup lang="ts">
import ModuleHost from './ModuleHost.vue'
import { modulesFor } from './registry'
import { isFocused } from '@/stores/ui'
import { isLoadingHidden } from '@/stores/loading'

/**
 * The root of the one surface. It renders the registry and nothing else.
 *
 * There were two CEF pages here, and collapsing them to one removed ~400 kB of
 * duplication -- the eight woff2 faces alone were 158 kB byte-identical in both, and
 * the Vue runtime and the whole design system came twice. What it cost is real and
 * worth knowing:
 *
 *   * ONE FRAME RATE. `fps` is fixed at `WebUI.create` and the page handle has no
 *     setter, so the HUD and a dragged inventory slot share whatever is configured.
 *     60 is the choice: a pointer that lags feels broken, while a HUD that repaints
 *     more often than it changes costs only what CEF charges for an undamaged frame.
 *   * NO CRASH ISOLATION BETWEEN LAYERS. Two pages meant an exception in a shop view
 *     could not blank the health bar. Now only ModuleHost stands between them, which
 *     is a boundary in one JS realm rather than two separate ones.
 *
 * Every module is a sibling under its own ModuleHost, deliberately: siblings cannot
 * reach each other, so one failing is contained by construction rather than by
 * discipline. Nesting a module inside another puts the inner one's failures inside the
 * outer one's blast radius.
 *
 * THE LOADING HIDE IS A `v-show` ON THE HOST, NOT A SWITCH IN ANY MODULE. A module
 * registered `hideWhileLoading` is taken off screen while the game's own loading screen
 * is up and put back when it ends -- without being told, so whatever made it open or
 * closed before the load is exactly what decides it after. `display: none` on the host
 * also wins over its `display: contents`, so nothing inside paints at all.
 */
const overlay = modulesFor('overlay')
const interactive = modulesFor('modal')
const notice = modulesFor('notice')
const cover = modulesFor('cover')
</script>

<template>
  <div class="surface">
    <div class="layer layer-overlay">
      <ModuleHost
        v-for="module in overlay"
        v-show="!(module.hideWhileLoading && isLoadingHidden)"
        :id="module.id"
        :key="module.id"
      >
        <component :is="module.component" />
      </ModuleHost>
    </div>

    <div class="layer layer-modal" :class="{ 'is-live': isFocused }">
      <ModuleHost
        v-for="module in interactive"
        v-show="!(module.hideWhileLoading && isLoadingHidden)"
        :id="module.id"
        :key="module.id"
      >
        <component :is="module.component" />
      </ModuleHost>
    </div>

    <div class="layer layer-notice">
      <ModuleHost
        v-for="module in notice"
        v-show="!(module.hideWhileLoading && isLoadingHidden)"
        :id="module.id"
        :key="module.id"
      >
        <component :is="module.component" />
      </ModuleHost>
    </div>

    <div class="layer layer-cover">
      <ModuleHost v-for="module in cover" :id="module.id" :key="module.id">
        <component :is="module.component" />
      </ModuleHost>
    </div>
  </div>
</template>

<style scoped>
.surface {
  position: fixed;
  inset: 0;
}

.layer {
  position: fixed;
  inset: 0;
}

/* Never takes a pointer. It sits over live gameplay, and a transparent full-screen div
   that eats pointer events is a player who cannot shoot. A module needing a pointer on
   this layer re-enables it on itself -- and nothing here should. */
.layer-overlay {
  pointer-events: none;
  user-select: none;
  z-index: 0;
}

/* Above the HUD, and inert until something on it actually holds focus. Without the
   `is-live` gate this layer would swallow every click for the whole session, because
   a closed view still renders an element that fills the screen. */
.layer-modal {
  pointer-events: none;
  z-index: 1;
}

.layer-modal.is-live {
  pointer-events: auto;
}

/* Over the modal layer, so a toast answering a form, a bag or the join screen is drawn
   on top of that view's scrim instead of dimmed under it. Never a pointer: a toast is
   read, not clicked, and this layer is full-screen. */
.layer-notice {
  pointer-events: none;
  user-select: none;
  z-index: 2;
}

/* Over everything, and never a pointer: the cover is drawn while the game is loading,
   and a load is nothing the player can click on. Empty -- and so free -- the rest of
   the time, because the cover renders nothing while it is down. */
.layer-cover {
  pointer-events: none;
  user-select: none;
  z-index: 3;
}
</style>
