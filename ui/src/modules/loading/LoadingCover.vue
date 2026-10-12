<script setup lang="ts">
import { computed } from 'vue'
import { useLocale } from '@/composables/useLocale'
import { loading } from '@/stores/loading'

/**
 * THE LOADING COVER -- the join screen's bay, over the game's own loading screen.
 *
 * It is drawn for the loads that happen in play: a teleport, a lift between floors, a
 * respawn. Lua decides when (`modules/loading`), and never for the join, which is the
 * platform's screen and is already dressed by `web/loading.html`. This file is the same
 * picture as that page -- the film or its poster, the two-stop scrim, one bay hinged on
 * the left edge holding the brand, the kind and the bar -- built from the design system
 * instead of a hand copy of it, because this one IS inside the bundle.
 *
 * IT NEVER SAYS DONE. The platform's fraction may sit at 1 while the screen is still
 * closing, and may move backwards; a bar that reached the end and then stayed up would
 * be a lie about the one thing it is for. So the figure stops at 99 and the fill a hair
 * short of the end, and the cover goes away only when Lua says the load is over -- which
 * is when the platform says `active` is false, and at no other moment.
 *
 * IT IS LIGHT BECAUSE IT IS ABSENT. Everything below is under one `v-if`: while no load
 * is up there is no element, no film decoder and no animation on this layer at all. Up,
 * it paints a full-screen picture over the game, so it carries no backdrop filter and no
 * drop shadow, and the only things that move are a `transform` on the bar and the film.
 *
 * The film and the poster are the join screen's own files, named at runtime: `web/` is
 * this page's own folder, and a bound `src` keeps the bundler from trying to inline a
 * 15 MB webm into the page.
 */
const FILM = 'loading.webm'
const POSTER = 'loading-poster.jpg'

/** Where the figure stops, in percent, and the fill with it. */
const CEILING = 0.99

const { t } = useLocale()

const kicker = computed(() =>
  t(loading.kind === 'fastTravel' ? 'loading.kind.fastTravel' : 'loading.kind.unknown')
)

const fraction = computed(() => Math.min(CEILING, Math.max(0, loading.progress)))

const percent = computed(() => Math.floor(fraction.value * 100))
</script>

<template>
  <Transition name="cover">
    <div v-if="loading.cover" class="cover">
      <div class="stage" :style="{ backgroundImage: `url(${POSTER})` }">
        <video
          v-if="loading.video"
          class="film"
          :src="FILM"
          :poster="POSTER"
          autoplay
          muted
          loop
          playsinline
          preload="auto"
        />
        <div class="scrim" />
      </div>

      <div class="dock op-plane op-anchor-left op-ink">
        <div class="bay op-bay op-arete" data-augmented-ui="tr-clip bl-clip border">
          <div class="bay-inner op-interlace">
            <div class="brand">
              <div class="mark">OPEN<b>//</b>77</div>
              <div class="mode op-eyebrow">Infinity</div>
            </div>

            <div class="progress">
              <div class="bar-line">
                <span class="bar-phase op-eyebrow op-truncate">{{ kicker }}</span>
                <span v-if="loading.progressKnown" class="bar-pct op-value">{{ percent }}%</span>
              </div>

              <div
                class="track"
                :class="{ busy: !loading.progressKnown }"
                data-augmented-ui="tr-clip border"
              >
                <span class="bar">
                  <span
                    class="fill"
                    :style="loading.progressKnown ? { transform: `scaleX(${fraction})` } : undefined"
                  />
                </span>
              </div>

              <p class="detail op-copy">
                {{ loading.progressKnown ? t('loading.title') : t('loading.pending') }}
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
  </Transition>
</template>

<style scoped>
/* =============================================================================
   The join screen's composition, from the design system rather than a copy of it.
   The ground is opaque: this is over the game's own loading screen, and a cover a
   player can see that screen through is two loading screens at once.
   ========================================================================== */

.cover {
  position: absolute;
  inset: 0;
  pointer-events: none;
  background: #05070a;
}

.cover-enter-active,
.cover-leave-active {
  transition: opacity var(--op-dur-slow) var(--op-ease);
}

.cover-enter-from,
.cover-leave-to {
  opacity: 0;
}

/* --- the film, full-bleed and behind everything ------------------------------ */

.stage {
  position: absolute;
  inset: 0;
  overflow: hidden;
  background-color: #000;
  background-position: center;
  background-size: cover;
}

.film {
  display: block;
  width: 100%;
  height: 100%;
  object-fit: cover;
}

/* Two stops, because one would have to grey the whole picture to make the bay legible.
   The join screen's own scrim, on the plate channels. */
.scrim {
  position: absolute;
  inset: 0;
  background:
    linear-gradient(
      to top,
      rgba(var(--op-plate-rgb), 0.94) 0%,
      rgba(var(--op-plate-rgb), 0.74) 16%,
      rgba(var(--op-plate-rgb), 0.3) 40%,
      rgba(var(--op-plate-rgb), 0) 66%
    ),
    linear-gradient(
      to right,
      rgba(var(--op-plate-rgb), 0.82) 0%,
      rgba(var(--op-plate-rgb), 0.34) 28%,
      rgba(var(--op-plate-rgb), 0) 54%
    );
}

/* --- the bay ------------------------------------------------------------------ */

/* Every offset pays the bleed back: `.op-plane` pads by `--op-bleed`. */
.dock {
  position: absolute;
  left: calc(var(--op-inset-x) - var(--op-bleed));
  bottom: calc(var(--op-inset-y) - var(--op-bleed));
  width: min(520px, 48vw);
}

.bay {
  position: relative;
  background: var(--op-plate-quiet);
}

.bay-inner {
  position: relative;
  display: grid;
  gap: var(--op-space-4);
  padding: var(--op-space-5);
}

.brand {
  display: grid;
  gap: var(--op-space-1);
}

/* A flex row and not a text run, for the join screen's reason: as an inline box the
   accent `//` stands taller than its line and hangs into the row below. */
.mark {
  display: flex;
  align-items: baseline;
  font: 700 clamp(var(--op-fs-head), 3.4vw, var(--op-fs-hero)) / 0.9 var(--op-font-display);
  letter-spacing: var(--op-track-head);
  text-transform: uppercase;
  color: var(--op-text);
}

.mark b {
  color: var(--op-red);
}

.mode {
  color: var(--op-red-text);
}

/* --- the gauge: HudVitals' track, the join screen's sweep --------------------- */

.progress {
  display: grid;
  gap: var(--op-space-2);
}

.bar-line {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: var(--op-space-2);
}

.bar-phase {
  color: var(--op-red-text);
}

.bar-pct {
  color: var(--op-red-hi);
  font-size: var(--op-fs-label);
}

.track {
  position: relative;
  display: block;
  height: 14px;
  padding: 3px;

  --aug-tr: var(--op-cut-sm);
}

/* The cut the frame's chamfer leaves, less the 3px inset, so the bar ends on the
   diagonal rather than poking a square corner through it. */
.bar {
  display: block;
  width: 100%;
  height: 100%;
  overflow: hidden;
  clip-path: polygon(
    0 0,
    calc(100% - (var(--op-cut-sm) - 3px)) 0,
    100% calc(var(--op-cut-sm) - 3px),
    100% 100%,
    0 100%
  );
}

/* `scaleX`, never `width`: the fraction moves for the whole load, and a width is a
   relayout per step. It may move BACKWARDS -- the platform says it can -- and the
   transition draws that as it is rather than hiding it. */
.fill {
  display: block;
  width: 100%;
  height: 100%;
  background: var(--op-red);
  transform-origin: left center;
  transform: scaleX(0);
  transition: transform var(--op-dur-slow) linear;
}

/* No fraction yet: a third of a bar sweeping, the join screen's "no idea yet". */
.track.busy .fill {
  transition: none;
  animation: loading-sweep 1.1s var(--op-ease) infinite;
}

@keyframes loading-sweep {
  from {
    transform: translateX(-110%) scaleX(0.34);
  }
  to {
    transform: translateX(360%) scaleX(0.34);
  }
}

.detail {
  margin: 0;
  min-height: calc(var(--op-fs-meta) * 1.4);
  color: var(--op-text-faint);
}

@media (prefers-reduced-motion: reduce) {
  .track.busy .fill {
    animation: none;
    transform: scaleX(0.34);
  }
}

/* =============================================================================
   THE MINIMAL STYLE
   =============================================================================
   THE HOUSE PAGE, NOT A TERMINAL BOOTING. The cover is a white page with two
   hairline rails down its sides, as the house site is drawn; the film still
   plays, but framed -- a picture set into the page on the right, with a
   hairline and a soft shadow -- rather than as the ground under everything.
   The wordmark is huge and in the lightest weight the face has, with the `//`
   the one bold mark in it; under it, the phase and the percentage on one line
   and a 2px progress line filled with the rainbow, the only colour on the
   page. */
:root[data-op-style="minimal"] .cover {
  background: var(--op-sheet);
}

:root[data-op-style="minimal"] .cover::before {
  content: '';
  position: absolute;
  inset: 0 24px;
  border-left: 1px solid var(--op-line);
  border-right: 1px solid var(--op-line);
  pointer-events: none;
}

:root[data-op-style="minimal"] .stage {
  inset: 10vh 6vw 10vh auto;
  width: 46vw;
  background-color: var(--op-sheet-sunk);
  box-shadow: 0 0 0 1px var(--op-line), var(--op-sheet-shadow);
}

:root[data-op-style="minimal"] .scrim {
  background: none;
}

:root[data-op-style="minimal"] .dock {
  left: 6vw;
  bottom: 10vh;
  width: min(560px, 40vw);
}

:root[data-op-style="minimal"] .bay {
  --aug-border-bg: transparent;
  background: none;
  box-shadow: none;
  text-shadow: none;
}

:root[data-op-style="minimal"] .bay-inner {
  gap: var(--op-space-6);
  padding: 0;
}

:root[data-op-style="minimal"] .brand {
  gap: var(--op-space-3);
}

:root[data-op-style="minimal"] .mark {
  font: 200 clamp(44px, 6.4vw, 104px) / 0.95 var(--op-font-display);
  letter-spacing: -0.05em !important;
  color: var(--op-text);
}

:root[data-op-style="minimal"] .mark b {
  margin: 0 0.04em;
  font-weight: 700;
  color: var(--op-text);
}

:root[data-op-style="minimal"] .mode {
  font: 300 var(--op-fs-lead) / 1.4 var(--op-font-body);
  color: var(--op-text-dim);
}

:root[data-op-style="minimal"] .progress {
  gap: var(--op-space-3);
}

:root[data-op-style="minimal"] .bar-phase {
  font: 400 var(--op-fs-meta) / 1.2 var(--op-font-body);
  color: var(--op-text);
}

:root[data-op-style="minimal"] .bar-pct {
  font: 600 var(--op-fs-meta) / 1.2 var(--op-font-body);
  color: var(--op-text);
}

/* The track is a 2px hairline-grey line; the fill is the rainbow sliding. */
:root[data-op-style="minimal"] .track {
  height: 2px;
  padding: 0;
  background: var(--op-line);
}

:root[data-op-style="minimal"] .track::after {
  content: none;
}

:root[data-op-style="minimal"] .bar {
  clip-path: none;
}

:root[data-op-style="minimal"] .fill {
  background-image: var(--op-rainbow-band);
  background-size: 200% 100%;
  animation: op-rainbow-slide 4s linear infinite;
}

/* Busy: the sweep stays, the slide rides along with it. */
:root[data-op-style="minimal"] .track.busy .fill {
  animation:
    loading-sweep 1.1s var(--op-ease) infinite,
    op-rainbow-slide 4s linear infinite;
}

:root[data-op-style="minimal"] .detail {
  font: 300 var(--op-fs-meta) / 1.5 var(--op-font-body);
  color: var(--op-text-faint);
}
</style>
