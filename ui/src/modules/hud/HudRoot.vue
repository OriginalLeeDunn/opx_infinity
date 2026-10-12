<script setup lang="ts">
import { onMounted, ref, shallowRef } from 'vue'
import { emit } from '@/bridge/channel'
import { num } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import HudInfo from './HudInfo.vue'
import HudStatus from './HudStatus.vue'
import HudVehicle from './HudVehicle.vue'
import HudVitals from './HudVitals.vue'
import HudVoice from './HudVoice.vue'
import { anchorOf } from './anchors'
import type { Anchor } from './anchors'

/**
 * THE HUD -- the port of `opx77_hud/web/{index.html,hud.js,hud.css}`.
 *
 * This file owns the LAYOUT and nothing else: where each block sits, and whether the HUD
 * is on screen at all. Every block below subscribes to its own channel and holds its own
 * state, which is the split that matters on this surface -- the vitals stream runs at
 * roughly 30 Hz and the money line changes when the player is paid. One `opx:hud:frame`
 * carrying both, as hud.js had, means re-rendering the street cred thirty times a second
 * to move a health bar.
 *
 * HIDDEN IS NOT UNMOUNTED. `open` is an opacity, exactly as `body.open` was in hud.css: a
 * block taken out of layout replays its entrance when it comes back, and every clock
 * under here keeps running while it is off screen, so what comes back is current rather
 * than a frame from before the player went down.
 *
 * DEFAULT VISIBLE. There is no Lua module behind `opx:hud:config` or `opx:hud:show` yet.
 * A HUD that waited for permission to draw would be a black screen until someone wrote
 * one, and on the surface that "must not stop drawing for any reason" the safe default is
 * on. Lua turns it off; Lua does not have to turn it on.
 *
 * -- DESIGN PASS 02 -----------------------------------------------------------
 *
 * THIS FILE IS NO LONGER THE HUD'S PALETTE, and that is the point of the port. It
 * carried the three red steps, the alarm, five 9-slice frame sprites and the ink
 * shadow, because a scoped rule cannot reach into a child component and a custom
 * property on `.hud` can. Every one of those is a `design-system/` token now, which
 * the five blocks read the same way and which eleven other surfaces read too -- so
 * the HUD stopped being a second place where the voice of the runtime is decided.
 *
 * WHAT IS STILL DECLARED HERE is what is true of THIS cluster and nothing else: the
 * bleed its wrappers need, the interlace its two enclosed blocks share, and the
 * layout below.
 *
 * NO FILTERS IN THIS FOLDER, with one written exception. A filter gives an element
 * its own backing store, and the vitals stream repaints thirty times a second; the
 * exception is `HudVoice`'s rx counter, which appears when somebody talks rather
 * than on a clock, and which needs a bloom that follows a cut corner.
 *
 * THE INK SHADOW IS ONE DECLARATION. `text-shadow` inherits, and this surface has no
 * backing of any kind, so every glyph under `.hud` -- in every block -- is carried by the
 * pair below. A block that wants a red bloom on a word restates BOTH passes plus the
 * bloom, because an override replaces the whole list.
 */

interface Layout {
  anchor: Anchor
  infoAnchor: Anchor
  statusAnchor: Anchor
  /** Pixels of clearance between the status strip and the vitals column beneath it. */
  statusOffset: number
  vehicleAnchor: Anchor
  width: number
  segments: number
  voiceSegments: number
}

const DEFAULTS: Layout = {
  anchor: 'bottom-left',
  infoAnchor: 'top-right',
  statusAnchor: 'bottom-left',
  statusOffset: 120,
  vehicleAnchor: 'bottom-center',
  width: 210,
  segments: 10,
  voiceSegments: 8
}

const layout = shallowRef<Layout>(DEFAULTS)
const visible = ref(true)

useBridge('opx:hud:config', (payload: Payload) => {
  const anchor = anchorOf(payload.anchor, DEFAULTS.anchor)
  const segments = Math.round(num(payload.segments, DEFAULTS.segments))
  const voiceSegments = Math.round(num(payload.voiceSegments, DEFAULTS.voiceSegments))
  const width = num(payload.width, DEFAULTS.width)
  const statusOffset = num(payload.statusOffset, DEFAULTS.statusOffset)

  layout.value = {
    anchor,
    infoAnchor: anchorOf(payload.infoAnchor, DEFAULTS.infoAnchor),
    // The strip rides in the vitals column's corner until Lua says otherwise, which is
    // hud.js `stripFallback` -- and it has to be read out of THIS payload's anchor, not
    // the one that was in force before it.
    statusAnchor: anchorOf(payload.statusAnchor, anchor),
    statusOffset: statusOffset >= 0 ? Math.round(statusOffset) : DEFAULTS.statusOffset,
    vehicleAnchor: anchorOf(payload.vehicleAnchor, DEFAULTS.vehicleAnchor),
    width: width > 0 ? Math.round(width) : DEFAULTS.width,
    // Two is the fewest that still reads as segmented rather than as a light.
    segments: segments >= 2 ? segments : DEFAULTS.segments,
    voiceSegments: voiceSegments >= 2 ? voiceSegments : DEFAULTS.voiceSegments
  }
})

useBridge('opx:hud:show', (payload: Payload) => {
  // `!== false` and not `=== true`: any other value, `nil` included, shows. That is the
  // `setVisible` contract in opx77_hud/client/exports.lua and players inherit it.
  visible.value = payload.visible !== false
})

onMounted(() => {
  emit('opx:hud:ready', {})
})
</script>

<template>
  <div class="hud" :class="{ open: visible }">
    <div class="at" :class="layout.anchor">
      <HudVitals :segments="layout.segments" :width="layout.width" />
    </div>

    <div class="at" :class="layout.infoAnchor">
      <HudInfo :anchor="layout.infoAnchor" />
    </div>

    <div
      class="at"
      :class="layout.statusAnchor"
      :style="{ '--block-offset': layout.statusOffset + 'px' }"
    >
      <HudStatus />
    </div>

    <div class="at" :class="layout.vehicleAnchor">
      <HudVehicle />
    </div>

    <!-- The voice block pins itself: it is the one read-out with no anchor, because it is
         the only one that is not a cluster of one edge but a single tall column, and it
         reads the bottom-right corner -- the one corner voting leaves free (vitals and the
         chip strip are bottom-left, the vehicle chip is bottom-centre, the info block is
         top-right). It therefore carries its own perspective and its own tilt sign; every
         other block gets both from the `.at` it sits in. -->
    <HudVoice :segments="layout.voiceSegments" />
  </div>
</template>

<style scoped>
/* =============================================================================
   DESIGN PASS 02 -- RED, OUTLINED, TILTED. The HUD's half of it.

   The menu settled the language and this folder takes it. What is different
   about the HUD, and what every decision below turns on:

     * IT REPAINTS CONTINUOUSLY. A menu changes when a key is pressed; the
       vitals stream is ~30 Hz and the speedometer moves whenever the car does.
       So the rules that are advisory on a menu are load-bearing here: no
       `filter` on anything whose value changes, no fill that has to be
       re-rasterised, and a moving quantity moves by `transform` -- the one
       thing the compositor can do without a repaint at all.
     * IT HAS NO BACKING WHATSOEVER. Not even the menu's veil dial is raised.
       Every glyph sits on live gameplay, which is why `text-shadow` is
       declared once here and inherited by all five blocks.
     * IT IS FIVE CLUSTERS, NOT ONE SURFACE. Each is anchored to a different
       screen edge, so each gets its own tilt sign -- and the one Lua anchors
       to a centre gets none.
   ========================================================================== */

.hud {
  /* THE BLACK UNDER AN UNCHAMFERED BOX. A cut shape needs a `drop-shadow`,
     which follows the diagonal; this is the plain outset one, and its two
     remaining users are both on the voice meter, which has no chamfer. */
  --hud-shadow: var(--op-shadow);

  /* How much room a cluster's shadows and blooms need INSIDE its wrapper. The
     wrapper clips (see `.at`), so the bleed is padding and the anchor offsets
     pay it straight back. */
  --hud-bleed: 10px;

  /* The interlace, for the two clusters that have an enclosing frame to put it
     on. `.op-interlace` is the same gradient on a free `::before`; this stays a
     variable because both of its users paint it into a composite background
     rather than onto a pseudo-element of their own. */
  --hud-interlace: repeating-linear-gradient(
    to bottom,
    var(--op-interlace) 0 1px,
    transparent 1px 3px
  );

  position: absolute;
  inset: 0;
  opacity: 0;

  /* THE ONE INK SHADOW FOR THE WHOLE HUD. It inherits, so this single
     declaration carries every label, every number and every readout in all
     five blocks. Two passes: the tight dark one gives a glyph its edge, the
     wide soft one lifts it off a blown-out plaza. */
  text-shadow:
    0 1px 2px rgba(0, 0, 0, 0.95),
    0 0 9px rgba(0, 0, 0, 0.8);

  /* Layout and style containment here; the PAINT containment is one level down,
     on each cluster, which is where it buys something and where the bleed has
     been budgeted for it. Note what layout containment already does: it makes
     this element the containing block for its `position: fixed` children. That
     is safe only because `.hud` is `inset: 0` inside `.layer-overlay`, which is
     itself fixed at `inset: 0` -- so this box IS the viewport box and every
     `.at` lands exactly where it did before. Take that guarantee away and the
     five clusters move. */
  contain: layout style;
  /* It cuts, it does not fade. */
  transition: opacity var(--op-enter-ms) var(--op-stutter);
}

.hud.open {
  opacity: 1;
}

/* =============================================================================
   A CLUSTER'S WRAPPER -- the positioned element, so this is what carries the
   perspective, the containment and the tilt SIGN. The block inside it is the
   plane that rotates; perspective on the plane itself would give every
   descendant its own vanishing point.

   THE BLEED. `contain: paint` clips to the padding box, and a black shadow or
   a bloom landing outside it is simply gone -- so the wrapper is padded by
   `--hud-bleed` and every anchor offset below subtracts the same amount. The
   cluster ends up exactly where `--op77-inset-*` put it, with 10px of room
   around it that nothing can paint outside of.
   ========================================================================== */
.at {
  position: fixed;
  box-sizing: border-box;
  display: flex;
  padding: var(--hud-bleed);
  max-width: calc(100vw - var(--op-inset-x) * 2 + var(--hud-bleed) * 2);
  perspective: var(--op-persp);
  contain: layout paint style;
}

.bottom-left,
.top-left {
  left: calc(var(--op-inset-x) - var(--hud-bleed));
  justify-content: flex-start;
  /* A LEFT-anchored surface gets +7deg and pivots on the left edge. */
  --tilt: var(--op-tilt);
  --origin: left center;
}

.bottom-right,
.top-right {
  right: calc(var(--op-inset-x) - var(--hud-bleed));
  justify-content: flex-end;
  /* A RIGHT-anchored one gets -7deg and pivots on the right. */
  --tilt: calc(var(--op-tilt) * -1);
  --origin: right center;
}

/* A CENTRED CLUSTER GETS NO TILT. There is no edge for it to recede towards,
   and 7deg about its own middle is not a plane on the inside of a visor -- it
   is a card lying on a table. */
.top-center,
.bottom-center {
  left: 50%;
  transform: translateX(-50%);
  justify-content: center;
  --tilt: 0deg;
  --origin: center center;
}

.bottom-left,
.bottom-right,
.bottom-center {
  bottom: calc(var(--op-inset-y) + var(--block-offset, 0px) - var(--hud-bleed));
}

.top-left,
.top-right,
.top-center {
  top: calc(var(--op-inset-y) + var(--block-offset, 0px) - var(--hud-bleed));
}
</style>
