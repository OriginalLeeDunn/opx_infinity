<script setup lang="ts">
import { computed } from 'vue'
import { useLocale } from '@/composables/useLocale'
import { GLYPHS } from '@/modules/target/glyphs'
import { own } from '@/bridge/types'

/**
 * ONE TOAST -- design pass 02.
 *
 * WHY THIS IS NOT `design/components/OpToast.vue`. It was, and that component is
 * still there untouched. Pass 02 is agreed on the menu surface only, and
 * `MenuView.vue` says what to do about that in as many words: it dropped `OpPanel`
 * and `OpRow` for local copies "because those two are shared... and changing them
 * changes every surface at once", and the local copy is deleted when the pass is
 * promoted into `design/`. `OpToast` has exactly one consumer -- this module -- so
 * nothing else moves when it is left behind, and the same rule applies for the same
 * reason: `ui/src/design/**` is off limits until the pass lands.
 *
 * WHAT CAME ACROSS FROM IT, unchanged: the shape (a leading icon column, a body, a
 * 2px lifetime bar), the `progress` contract (0..1, or -1 for "draw no bar", set by
 * width and never by a keyframe, because the bar tracks a deadline Lua is also
 * counting), and the rule that severity is one variable and moves as little as
 * possible. What did not: the fill, `data-augmented-ui`, `op-panel`, `op-lift`, the
 * `--op77-notch-clip` shape, and `--op77-accent` -- which `.op-theme-city` makes
 * Night City yellow on <html>, and pass 02 bans yellow outright.
 *
 * THE ICON IS A GLYPH NOW, not a text badge. `OpToast` took "up to a few characters
 * of caller text", which is what the PLATFORM's own notification package means by
 * `icon` (a short badge, at most 16 bytes). This surface is not that package: it is
 * our page, fed by `core/client/notify.lua`, so `icon` here is a name from the
 * closed glyph set and Lua refuses a toast naming anything outside it.
 */
const props = withDefaults(
  defineProps<{
    title: string
    message?: string
    /** A glyph name from the closed set Lua validates against, or '' for none. */
    icon?: string
    kind?: 'info' | 'success' | 'warning' | 'error'
    /** 0..1, or -1 for "draw no bar". Lua owns the lifetime; this is its remainder. */
    progress?: number
  }>(),
  { message: '', icon: '', kind: 'info', progress: -1 }
)

const { t, has } = useLocale()

/**
 * THE KIND, IN WORDS. Rule 8 of the pass: technical filler is content, and a
 * micro-label has to state something the surface actually knows. The kind is the
 * one thing every toast knows about itself, and now that toasts are the runtime's
 * only channel for "that worked" / "that failed" it is the thing a player most
 * needs off a glance -- so it is said outright rather than left to be inferred
 * from a frame's weight.
 *
 * A catalogue key first, because the page holds no English (see `useLocale`). The
 * fallback is not a sentence, it is a four-character mono tag of the same class as
 * `FormView`'s `FORM`, and it exists so this reads correctly before anyone adds
 * `notify.kind.*` to `locales/`. `has` rather than `t` alone: `t` renders a missing
 * key AS the key, and `notify.kind.error` in the tag slot would be worse than
 * nothing.
 */
const TAGS: Record<string, string> = {
  info: 'NOTICE',
  success: 'CONFIRMED',
  warning: 'CAUTION',
  error: 'FAILED'
}

const tag = computed(() => {
  const key = `notify.kind.${props.kind}`
  return has(key) ? t(key) : TAGS[props.kind]
})

/** The paths of one glyph, empty for a toast carrying none and for a name this page
    does not know. The set is CLOSED and Lua refuses a toast naming anything outside
    it, so an empty answer here means a toast with no icon, never a silent typo --
    the same call, for the same reason, as `MenuView.vue`'s `paths`.

    Imported from the target module rather than re-declared: it is one closed set,
    now shared by three surfaces. It belongs in `design/` and moves there when this
    pass is promoted. */
const glyph = computed<string[]>(() => (props.icon && own(GLYPHS, props.icon)) || [])

const barScale = computed(() => `scaleX(${Math.max(0, Math.min(1, props.progress))})`)
</script>

<template>
  <article
    class="toast op-frame op-arete op-interlace op-ink"
    :class="[kind, { 'op-lift': kind === 'error' }]"
    data-augmented-ui="tr-clip border"
  >
    <!-- No column is held open for an absent glyph, and this is the one place this
         surface parts with the menu. A row holds its icon column open so every
         label in a dense column lands on one x; a toast is three lines tall with a
         title of its own, arrives alone, and most of them carry no icon at all --
         so an empty 18px gutter on every toast would be paid for by all of them to
         align two that are rarely on screen together. -->
    <span v-if="glyph.length" class="glyph" aria-hidden="true">
      <svg viewBox="0 0 24 24">
        <path v-for="(d, at) in glyph" :key="at" :d="d" />
      </svg>
    </span>

    <div class="body">
      <!-- The mono micro-label, as every eyebrow on the surface is. Its own rule was
           lost in the move to the design system and it had been drawing at body size,
           as loud as the message under it. -->
      <span class="tag op-eyebrow">{{ tag }}</span>
      <!-- A toast with no title is common (`inventory.change` sends none), and the
           tag standing in as the header line is why this order is tag-then-title. -->
      <span v-if="title" class="title">{{ title }}</span>
      <span v-if="message" class="message">{{ message }}</span>
    </div>

    <!-- Driven, not a CSS animation: the bar has to track the deadline Lua is also
         counting, and a keyframe drifts from it the moment the surface is throttled.
         A scale, not a width: the root ticks this every 50ms, and a width is a
         relayout plus a repaint of the whole toast -- under `.op-lift`, a filter
         re-rasterised twenty times a second. Same pixels. -->
    <span v-if="progress >= 0" class="bar" :style="{ transform: barScale }" />
  </article>
</template>

<style scoped>
/* =============================================================================
   ONE TOAST, on the design system.

   WHAT THIS FILE USED TO CARRY and no longer does: five inline SVG data URIs,
   one per kind plus a spare, each a copy of the same chamfer path with one
   stroke value changed; its own copy of the red ladder; its own ink shadow; its
   own interlace gradient. All four now come from `design-system/`, and this file
   says only what is TRUE OF A TOAST.

   RED IS THE VOICE, SO RED CANNOT BE THE ALARM -- and a toast has four kinds,
   which is the hard version of that problem. A second saturated hue is not
   available: two hues on an unfilled red surface over live gameplay is the
   yellow-accent mistake with extra steps. So the kinds are told apart on three
   axes already in the language, and a fourth that is words:

     1. TONE SAYS WHETHER SOMETHING IS WRONG. Red for `info` and `success`,
        white-hot for `warning` and `error`. White already means "something is
        wrong" everywhere in this runtime, so success must never take it.
     2. WEIGHT SAYS HOW LOUD. The border climbs 1px -> 1px -> 1.6px -> 2.4px,
        and only `error` blooms.
     3. LIT VERSUS AT REST SEPARATES THE TWO QUIET KINDS. `info` wears the
        resting arete every frame in the runtime wears; `success` is lit.
     4. AND THE KIND IS SAID IN WORDS, because the three above are read at a
        glance and a glance is all a toast gets.

   THE BLOOM IS A FILTER HERE, and that is a change forced by the shape. An
   outset `box-shadow` is cut off along the chamfer by the element's own clip,
   so `error` takes `.op-lift`, whose `drop-shadow` follows the cut. The rule
   that forbids filters is about elements that repaint every frame; a toast
   changes when Lua says something happened.
   ========================================================================== */

.toast {
  position: relative;
  display: flex;
  align-items: flex-start;
  gap: var(--op-space-3);
  /* The right pad clears the chamfer, so a long title never runs under the cut. */
  padding: var(--op-space-3) calc(var(--op-space-4) + var(--op-cut-md))
    var(--op-space-3) var(--op-space-4);
  /* The one shape token this surface overrides: a toast is panel-sized, so it
     takes the panel cut rather than the control cut `.op-frame` defaults to. */
  --aug-tr: var(--op-cut-md);
  /* A toast can change kind mid-life (`notify:update`), and that is its only
     state change. It cuts rather than fading, which is the house rule anyway. */
  transition: color var(--op-dur-fast) linear;
}

.glyph {
  flex: none;
  display: block;
  width: 18px;
  height: 18px;
  /* Optically on the tag's cap line rather than its box top. */
  margin-top: 2px;
}

.glyph svg {
  display: block;
  width: 100%;
  height: 100%;
  fill: none;
  /* Follows the toast's colour, so the glyph restates the kind -- including
     going white on a warning and an error -- without a second declaration. */
  stroke: currentcolor;
  stroke-width: 1.9;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.body {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 3px;
  min-width: 0;
}

.title {
  font: 700 var(--op-fs-title) / 1.15 var(--op-font-display);
  letter-spacing: 0.02em;
  text-transform: uppercase;
  /* A title is one caller-supplied line and may be a single long token. */
  overflow-wrap: anywhere;
}

.message {
  font: 400 var(--op-fs-body) / 1.35 var(--op-font-body);
  opacity: 0.82;
  overflow-wrap: anywhere;
}

/* The lifetime bar is the one filled mark on a toast, and it is a mark rather
   than a backdrop: an outlined 2px meter is not a meter, and remaining time is
   the one part of a toast that cannot be drawn as a stroke. */
.bar {
  position: absolute;
  left: 0;
  bottom: 0;
  width: 100%;
  height: 2px;
  background: var(--op-red-idle);
  transform-origin: left center;
  will-change: transform;
}

/* =============================================================================
   THE FOUR KINDS. Each moves the border paint, the tone, and nothing else.
   ========================================================================== */

/* INFO -- the resting arete, the thinnest frame, no bloom: red is the voice,
   and this is the voice saying something ordinary. The class comes from the
   design system; nothing is restated here. */

.success {
  --aug-border-bg: var(--op-red);
  color: var(--op-red);
}

.success .title {
  letter-spacing: 0.055em;
}

.success .bar {
  background: var(--op-red);
}

/* WARNING -- denser and white. `--op-red-deep` is the middle rung, which is the
   hover step everywhere else: denser rather than brighter, because a red that
   loses brightness on a night street loses the toast with it. */
.warning {
  --aug-border-bg: var(--op-red-deep);
  --aug-border-all: 1.6px;
  color: var(--op-alarm);
}

.warning .bar {
  background: var(--op-red-deep);
}

/* ERROR -- white, the heaviest frame, and the one bloom on the surface. The
   message takes full-strength text as well: a dim grey line inside a bright
   frame is the one combination that fails to read. */
.error {
  --aug-border-bg: var(--op-alarm);
  --aug-border-all: 2.4px;
  color: var(--op-alarm);
}

.error .message {
  opacity: 1;
}

.error .bar {
  background: var(--op-red);
}
</style>
