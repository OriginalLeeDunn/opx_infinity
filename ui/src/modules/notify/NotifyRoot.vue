<script setup lang="ts">
import { onMounted, onUnmounted, ref, shallowRef } from 'vue'
import NotifyToast from './NotifyToast.vue'
import { playClip, stingerOf, type Stinger } from './stinger'
import { emit } from '@/bridge/channel'
import { guard, report as diagReport } from '@/bridge/diag'
import { num, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * TOASTS -- the port of `opx77_notify/web/{index.html,notify.js,notify.css}`.
 *
 * THE PAGE OWNS THE CLOCK, and that is not a style choice here: `core/client/notify.lua`
 * has no expiry loop at all. It raises a toast carrying its whole lifetime, keeps the id
 * so it can address the toast later, and waits for this page to say the toast has gone.
 * If this module never emits `notify:gone`, Lua's `live` table grows for the session and
 * a dismiss aimed at a toast that left the screen minutes ago does nothing.
 *
 * WHY A TIMER AND NOT `requestAnimationFrame`, which is what notify.js used: rAF is
 * paced by painting, and a CEF surface that is throttled or not compositing stops
 * painting. Under notify.js that only stalled a progress bar, because Lua was counting
 * too and Lua removed the toast. Here a stalled clock is a toast that never expires and
 * never reports, so the countdown runs on a timer, which fires whether or not the
 * surface drew.
 *
 * WHY `useCountdown` IS NOT USED: it is display-only by contract -- it deliberately does
 * not fire a callback at zero, because a countdown on this platform is normally a smooth
 * animation of a deadline the server is also counting. This one IS the authority, so it
 * needs the one thing that composable refuses to do.
 *
 * ── THE STINGERS ──────────────────────────────────────────────────────────
 *
 * A toast may carry two clips, and they are the reason this page owns the reveal as
 * well as the clock. `open` plays first and the message is HELD until it ends: the
 * toast is live and addressable by Lua, and it is not drawn, and its lifetime has not
 * begun -- a message that is not on screen is not being read. `close` plays once the
 * message has gone, which is why it starts after the exit transition rather than with
 * it. A toast dismissed while still held plays neither: nothing ever appeared.
 *
 * NO STINGER IS EVER LOAD-BEARING. The clip helper answers on a deadline and on every
 * failure, so a missing file, a decoder that refuses it and a machine that will not
 * play audio all end the same way -- with the message drawn.
 *
 * ── DESIGN PASS 02 ──────────────────────────────────────────────────────────
 *
 * THIS MODULE DRAWS ITS OWN TOAST. `design/components/OpToast.vue` had exactly one
 * consumer -- this file -- and is still there, untouched: `ui/src/design/**` is closed
 * until the pass lands, and `MenuView.vue` set the precedent when it dropped `OpPanel`
 * and `OpRow` for local copies. `NotifyToast.vue` beside this file is that copy, and it
 * says in place what it kept and what it refused. Nothing else on the page imported
 * `OpToast`, so nothing else moved.
 *
 * WHAT THIS FILE OWNS OF THE LOOK: the seven stacks, which is where the PLANE lives.
 * A stack is the positioned wrapper, so it carries the perspective and names the screen
 * edge it is anchored to; the toast tilts because its entry does. Nothing about the
 * protocol changed -- same channels, same clock, same `notify:gone`.
 */
const { t } = useLocale()

type Kind = 'info' | 'success' | 'warning' | 'error'

/** The platform's seven, and only those. notify.js `POSITIONS`. */
type Position =
  | 'top_left'
  | 'top_center'
  | 'top_right'
  | 'middle_left'
  | 'bottom_left'
  | 'bottom_center'
  | 'bottom_right'

const POSITIONS: Position[] = [
  'top_left',
  'top_center',
  'top_right',
  'middle_left',
  'bottom_left',
  'bottom_center',
  'bottom_right'
]

const KINDS: readonly string[] = ['info', 'success', 'warning', 'error']

/** The page's own ceilings, repeating Lua's rather than trusting the sender for them. */
const MAX_PER_STACK = 8
const MAX_TOTAL = 32

/** How long a leaving toast stays mounted. Must be >= --op-dur-slow (220ms). */
const EXIT_MS = 260

/** 20 Hz. The bar is 2px of width; under the surface's 30fps and smooth enough for it. */
const TICK_MS = 50

const DEFAULT_MS = 5000

interface Toast {
  id: string
  /** The element's identity, unique per record for the page's life. NOT `id`: a toast
      re-shown under the id of one still running its exit puts two records with the
      same id in one stack for EXIT_MS, and duplicate `:key`s let Vue patch or remove
      the wrong element. A replace in place keeps the previous record's key. */
  key: number
  kind: Kind
  title: string
  message: string
  /** A glyph name from the closed set Lua validates against, or '' for none. */
  icon: string
  position: Position
  /** 0 is a PERSISTENT toast: no bar, no expiry, and no `notify:gone` ever. */
  durationMs: number
  /** Epoch ms, or 0 when persistent. This page's own arithmetic from arrival onwards. */
  endsAt: number
  /** Whether a lifetime bar was asked for at all -- notify.js `row.progress`. */
  bar: boolean
  /** 0..1, or -1 for "draw no bar", which is what the toast reads. */
  progress: number
  /** On its way out: still mounted so the exit transition can run. */
  out: boolean
  /** The two clips that wrap the message, or null for a toast carrying none. */
  stinger: Stinger | null
  /** Waiting on the opening clip: ALIVE and addressable, and not drawn. */
  held: boolean
  /** Whether the message was ever drawn. A toast dismissed while it was still held
   *  has no closing clip to play, because nothing went out to close. */
  revealed: boolean
}

/**
 * Replaced wholesale, never mutated in place. A `shallowRef` over plain objects costs one
 * dependency for the whole stack instead of one per field per toast, and there is nothing
 * here a deep proxy would buy: no descendant ever writes to a toast.
 */
const toasts = shallowRef<Toast[]>([])

/** notify.js `settings.position` -- where a toast with no position of its own lands. */
const fallbackPosition = ref<Position>('top_right')
const width = ref(340)

/** The player is down: the stacks go off screen and EVERY CLOCK KEEPS RUNNING. */
const down = ref(false)

let timer: ReturnType<typeof setInterval> | undefined

function positionOf(value: unknown, fallback: Position): Position {
  const name = text(value)
  return POSITIONS.indexOf(name as Position) === -1 ? fallback : (name as Position)
}

function kindOf(value: unknown): Kind {
  const name = text(value, 'info')
  return KINDS.indexOf(name) === -1 ? 'info' : (name as Kind)
}

/** The toasts of one stack, in arrival order. Bottom stacks reverse in CSS.
 *
 * A HELD toast is filtered out: the opening clip has not finished, so the message
 * it carries has not appeared yet. It stays in `toasts`, which is how a dismiss or
 * a clear from Lua can still address it. */
function at(position: Position): Toast[] {
  return toasts.value.filter((toast) => toast.position === position && !toast.held)
}

function liveCount(): number {
  let count = 0
  for (const toast of toasts.value) if (!toast.out) count += 1
  return count
}

/**
 * Starts a toast leaving and, after the transition, unmounts it.
 *
 * `report` decides whether Lua hears about it. A toast that ran out of time, or that this
 * page evicted to stay under its ceiling, is one Lua is still holding an id for and must
 * be told about. A dismiss or a clear came FROM Lua, which has already forgotten it --
 * reporting those back would be an echo.
 */
function leave(id: string, report: boolean): void {
  // The LIVE record for this id. During an exit a second, live one can share it, and
  // finding the leaving one first returned early: a dismiss or clear from Lua was
  // lost, and a persistent toast stayed up for the session under a forgotten id.
  const toast = toasts.value.find((entry) => entry.id === id && !entry.out)
  if (!toast) return

  toasts.value = toasts.value.map((entry) =>
    entry === toast ? { ...entry, out: true, progress: -1 } : entry
  )
  if (report) emit('opx:notify:gone', { id })

  // The closing clip starts when the exit has FINISHED, which is what "after it has
  // gone" means, and only for a message that was actually drawn.
  const closing = toast.revealed && toast.stinger ? toast.stinger.close : ''
  const volume = toast.stinger ? toast.stinger.volume : 1

  window.setTimeout(() => {
    toasts.value = toasts.value.filter((entry) => entry.key !== toast.key)
    if (closing) void playStinger(closing, volume, 'close')
  }, EXIT_MS)
}

/** Plays one clip and leaves a line behind when it produced no sound. */
async function playStinger(name: string, volume: number, which: string): Promise<void> {
  const played = await playClip(name, volume)
  if (!played.played && played.reason) diagReport(played.reason, `notify ${which} stinger ${name}`)
}

/** Unmounts immediately, with no exit transition. The eviction path only. */
function evict(position: Position): void {
  // A held toast is skipped: it has not been seen, so evicting it would drop an
  // announcement nobody has read yet. The stack may run one over its ceiling while a
  // clip plays, which the total below still bounds.
  const oldest = toasts.value.find((toast) => toast.position === position && !toast.out && !toast.held)
  if (!oldest) return
  // Told to Lua: it is holding this id, and from here on nothing can address it.
  emit('opx:notify:gone', { id: oldest.id })
  toasts.value = toasts.value.filter((toast) => toast !== oldest)
}

/** Builds the record a payload describes, over `previous` when this is a patch. */
let serial = 0

function build(payload: Payload, previous: Toast | undefined): Toast {
  const durationMs = Math.max(
    0,
    Math.round(num(payload.durationMs, previous ? previous.durationMs : DEFAULT_MS))
  )

  // A patch that does not change the lifetime keeps the deadline the toast already had.
  // Without this, a caller updating a progress line once a second restarts the bar once a
  // second and the toast never expires.
  const sameLife = previous !== undefined && previous.durationMs === durationMs
  let endsAt = sameLife ? previous.endsAt : 0
  if (durationMs === 0) {
    endsAt = 0
  } else if (!sameLife || typeof payload.remainingMs === 'number') {
    // `remainingMs` is how a toast held before this page was ready resumes mid-life
    // instead of starting a full bar and vanishing before it has emptied.
    const left = Math.max(0, Math.min(durationMs, num(payload.remainingMs, durationMs)))
    endsAt = Date.now() + left
  }

  // A persistent toast has no lifetime to draw, whatever the caller asked for.
  const bar = durationMs > 0 && payload.progress !== false && (previous ? previous.bar : true)

  return {
    id: text(payload.id),
    key: previous ? previous.key : ++serial,
    kind: payload.kind === undefined && previous ? previous.kind : kindOf(payload.kind),
    // A locale KEY or the sentence Lua already resolved: `t` returns anything it does not
    // know unchanged, so both spellings pass through the same call.
    title: payload.title === undefined && previous ? previous.title : t(text(payload.title)),
    message:
      payload.message === undefined && previous ? previous.message : t(text(payload.message)),
    // A GLYPH NAME, not caller text. The platform's own notification package means a
    // short badge by `icon` and truncated at 16 characters for it; this is our page and
    // `core/client/notify.lua` refuses a toast naming a glyph outside the closed set, so
    // what arrives here is a name or nothing. Carried as the string it is: the component
    // that draws it is where an unknown name resolves to no icon.
    icon: payload.icon === undefined && previous ? previous.icon : text(payload.icon),
    position: positionOf(payload.position, previous ? previous.position : fallbackPosition.value),
    durationMs,
    endsAt,
    bar,
    progress: bar ? 1 : -1,
    // A patch that carries no stinger keeps the one the toast already had, exactly
    // as a patch that carries no kind keeps its kind.
    stinger:
      payload.stinger === undefined && previous ? previous.stinger : stingerOf(payload.stinger),
    // Both of these belong to the toast that is already on screen, not to the patch:
    // a caller updating a progress line must not put a revealed message back into
    // the hold, nor make it forget it was ever drawn.
    held: previous ? previous.held : false,
    revealed: previous ? previous.revealed : false,
    out: false
  }
}

/** Plays a toast's opening clip and draws the message when it has finished. */
async function openThenReveal(id: string, stinger: Stinger): Promise<void> {
  const name = stinger.open
  if (!name) {
    reveal(id)
    return
  }
  await playStinger(name, stinger.volume, 'open')
  reveal(id)
}

/**
 * Draws a held toast and starts its lifetime, which had not begun.
 *
 * A no-op for a toast that has already been drawn, was dismissed, or was cleared
 * while the clip was playing -- all three are ordinary, because dismissing a toast
 * does not stop audio that has already been sent to the device.
 */
function reveal(id: string): void {
  const toast = toasts.value.find((entry) => entry.id === id && entry.held && !entry.out)
  if (!toast) return

  // The life comes from `durationMs` and not from the bar: a caller asking for no bar
  // is asking for no METER, and the toast still expires. 0 is a persistent toast, and
  // it stays one.
  const lifetime = toast.durationMs
  toasts.value = toasts.value.map((entry) =>
    entry === toast
      ? { ...entry, held: false, revealed: true, endsAt: lifetime > 0 ? Date.now() + lifetime : 0,
          progress: entry.bar && lifetime > 0 ? 1 : -1 }
      : entry
  )
  pump()
}

/**
 * Draws a new toast or redraws a known one.
 *
 * `notify:update` lands here too, exactly as notify.js folded `notify:add` and
 * `notify:update` into one `add`: a page that reloaded mid-session does not know the id
 * an update names, and refusing it would lose the toast rather than redraw it.
 */
function put(payload: Payload): void {
  const id = text(payload.id)
  if (!id) return

  const previous = toasts.value.find((toast) => toast.id === id && !toast.out)
  const next = build(payload, previous)

  if (previous) {
    // Replaced in place: same index in the stack, same element, so the entrance animation
    // does not replay under a caller that patches once a second.
    toasts.value = toasts.value.map((toast) => (toast === previous ? next : toast))
    pump()
    return
  }

  // Reaching Lua's own ceiling means something other than Lua is talking to this page.
  if (liveCount() >= MAX_TOTAL) return
  if (at(next.position).filter((toast) => !toast.out).length >= MAX_PER_STACK) {
    evict(next.position)
  }
  // A toast with an opening clip is HELD before it is added, and never after: the
  // stack is a `shallowRef`, so a field written on a record that is already in it
  // would be a mutation nothing redraws. It is added held -- so a second announcement
  // replaces it, and an operator can dismiss it -- and `reveal` puts it on screen when
  // the clip ends. Nothing about its lifetime is running yet.
  const held = next.stinger !== null && next.stinger.open !== ''
  if (held) {
    next.held = true
    next.endsAt = 0
    next.progress = -1
  }

  toasts.value = [...toasts.value, next]
  if (held && next.stinger) void openThenReveal(next.id, next.stinger)
  pump()
}

/** One pass: every bar's remainder, and every deadline that has come due. */
function tick(): void {
  const atMs = Date.now()
  const expired: string[] = []
  let running = false
  let changed = false

  const next = toasts.value.map((toast) => {
    if (toast.out || toast.endsAt === 0) return toast
    const left = Math.max(0, Math.min(1, (toast.endsAt - atMs) / toast.durationMs))
    if (left <= 0) {
      expired.push(toast.id)
      return toast
    }
    running = true
    if (!toast.bar) return toast
    // A bar is 2px tall: redrawing for a change smaller than a screen pixel is work
    // nobody can see, twenty times a second, for as long as a toast is up.
    if (Math.abs(left - toast.progress) < 0.002) return toast
    changed = true
    return { ...toast, progress: left }
  })

  if (changed) toasts.value = next
  // `leave` rewrites the array itself, so it runs after the map and never inside it.
  for (const id of expired) leave(id, true)
  if (!running && expired.length === 0) stop()
}

function pump(): void {
  if (timer !== undefined) return
  // A throw inside a timer is not a throw inside a bridge handler: channel.ts is not
  // above it, and nothing else would ever report it.
  timer = setInterval(() => guard('notify tick', tick, undefined), TICK_MS)
}

function stop(): void {
  if (timer === undefined) return
  clearInterval(timer)
  timer = undefined
}

useBridge('opx:notify:config', (payload: Payload) => {
  fallbackPosition.value = positionOf(payload.position, fallbackPosition.value)
  const wanted = num(payload.width)
  if (wanted > 0) width.value = Math.round(wanted)
})

useBridge('opx:notify:show', put)
useBridge('opx:notify:update', put)

useBridge('opx:notify:dismiss', (payload: Payload) => {
  // No `notify:gone`: this came from Lua, which has already dropped the id.
  leave(text(payload.id), false)
})

useBridge('opx:notify:clear', () => {
  for (const toast of toasts.value) leave(toast.id, false)
})

useBridge('opx:notify:down', (payload: Payload) => {
  down.value = payload.down === true
})

onMounted(() => {
  // An INTENT: "this module is mounted and bound". Lua decides whether to replay what it
  // is holding. Per module and not per surface, because ModuleHost can remount a module
  // long after the surface announced itself.
  emit('opx:notify:ready', {})
})

onUnmounted(stop)
</script>

<template>
  <div class="notify" :class="{ down }" :style="{ '--toast-width': width + 'px' }">
    <div v-for="position in POSITIONS" :key="position" class="stack" :class="position">
      <!-- A wrapper per toast, and it is the tilted plane: it is the direct child of the
           stack, which is where the perspective is, so it is the one element whose
           `rotateY` is actually projected. The entrance and the exit move the same
           property, so both restate the rotation rather than composing with it -- which
           is what `MenuView.vue` does in `plate-in-on` for the same reason. -->
      <div v-for="toast in at(position)" :key="toast.key" class="entry" :class="{ out: toast.out }">
        <NotifyToast
          :kind="toast.kind"
          :title="toast.title"
          :message="toast.message"
          :icon="toast.icon"
          :progress="toast.progress"
        />
      </div>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   DESIGN PASS 02 -- the stacks. `MenuView.vue`'s style block is the spec; the toast
   itself is drawn by `NotifyToast.vue` beside this file, and everything here is the
   surface it stands on: where a stack sits, which way its plane tilts, and how a
   toast arrives and leaves.
   ========================================================================== */
.notify {
  position: absolute;
  inset: 0;
}

/* The player is down. `visibility`, not `display`: a node taken out of layout replays its
   entrance animation when it comes back, and every clock under here is still running, so
   what comes back is what is still due. */
.down .stack {
  visibility: hidden;
}

/* A STACK IS THE POSITIONED WRAPPER, so it is the element that carries the camera:
   `perspective` here and `rotateY` on its child, because perspective on the child
   would give every descendant of it a vanishing point of its own.

   `contain` WITHOUT `paint`, deliberately. Layout and style containment are what the
   performance rule is after -- the compositor never considers the rest of the surface
   when one toast repaints -- but paint containment clips to the border box, and every
   toast here carries an outset black shadow and an error carries a bloom. A clipped
   shadow is a straight bright-edged line down the side of the stack, which is worse
   than the frame it was hiding. */
.stack {
  position: fixed;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-2);
  width: var(--toast-width, 340px);
  max-width: calc(100vw - var(--op-inset-x) * 2);
  perspective: var(--op-persp);
  contain: layout style;
}

.top_left,
.top_center {
  top: var(--op-inset-y);
}

/* THE READ-OUT IS ALREADY UP THERE. `HudInfo.vue` anchors `top-right` by default --
   money, job, street cred -- and a toast stack pinned to the same inset landed on
   top of it, which is where the owner found it.

   A fixed clearance and not a measured one: the two live in different modules on one
   surface, and the alternative is the read-out publishing its height for the toasts
   to subscribe to, which is a bridge between two things that have no other reason to
   know about each other. The read-out is a handful of short lines, so the number is
   stable; it is a token so that moving it is moving one value. */
.top_right {
  top: calc(var(--op-inset-y) + var(--op-notify-clear-top, 31vh));
}

/* Bottom stacks grow upward, so the newest toast is nearest the edge. DOM order is the
   same in every stack, so nothing in script has to know which way one grows. */
.bottom_left,
.bottom_center,
.bottom_right {
  bottom: var(--op-inset-y);
  flex-direction: column-reverse;
}

/* THE PLANE IS TILTED, and the sign follows the edge the stack is anchored to: a
   LEFT-anchored surface takes +7deg about its left edge, a RIGHT-anchored one -7deg
   about its right. One axis only.

   `--pop` and `--pop-y` are the same edge read again as a direction: a toast arrives
   from off the edge its stack is pinned to, and leaves the same way. Exactly one of
   the two is non-zero for any stack, which is what lets all seven positions share one
   set of keyframes where there were four. */
.top_left,
.bottom_left,
.middle_left {
  left: var(--op-inset-x);
  --tilt: var(--op-tilt);
  --origin: left center;
  --pop: -12px;
}

.top_right,
.bottom_right {
  right: var(--op-inset-x);
  --tilt: calc(var(--op-tilt) * -1);
  --origin: right center;
  --pop: 12px;
}

/* A CENTRED STACK DOES NOT TILT. The tilt is a surface turning about the screen edge
   it is anchored to, and these two are anchored to nothing -- a centred plane rotated
   about its own middle is not a surface receding, it is a sheet of paper twisting.
   They keep the stutter and enter on the vertical instead. */
.top_center,
.bottom_center {
  left: 50%;
  transform: translateX(-50%);
  --tilt: 0deg;
  --origin: center;
}

.top_center {
  --pop-y: -8px;
}

.bottom_center {
  --pop-y: 8px;
}

/* The one position with no vertical partner in the platform's set. */
.middle_left {
  top: 50%;
  transform: translateY(-50%);
}

/* =============================================================================
   ARRIVING AND LEAVING -- it cuts, it does not fade.

   `--op-stutter` on both, `opacity` and `transform` only, which the compositor runs
   without a repaint. The entrance overshoots by a sixth of its own travel and settles,
   so three frames read as a stutter rather than as a slide with a low frame rate.

   NO STAGGER, and that is the one line of the contract this surface answers with a
   reason instead of a value. The menu's 28ms stagger is for a batch revealed at once;
   toasts arrive one at a time, when something happens, and the index a stagger would
   have to key off is a toast's POSITION IN ITS STACK -- so the third toast up would
   sit invisible for 84ms after the event that raised it, which is exactly the report a
   player needs soonest.
   ========================================================================== */
.entry {
  transform-origin: var(--origin, center);
  transform: rotateY(var(--tilt, 0deg));
  animation: toast-in var(--op-enter-ms) var(--op-stutter);
  transition:
    opacity var(--op-dur-slow) var(--op-stutter),
    transform var(--op-dur-slow) var(--op-stutter);
}

/* Leaving is arriving, played backwards: out the edge it came in by. */
.entry.out {
  opacity: 0;
  transform: translate3d(var(--pop, 0px), var(--pop-y, 0px), 0) rotateY(var(--tilt, 0deg));
}

@keyframes toast-in {
  0% {
    opacity: 0;
    transform: translate3d(var(--pop, 0px), var(--pop-y, 0px), 0) rotateY(var(--tilt, 0deg));
  }

  55% {
    opacity: 1;
    transform: translate3d(
        calc(var(--pop, 0px) * -0.16),
        calc(var(--pop-y, 0px) * -0.16),
        0
      )
      rotateY(var(--tilt, 0deg));
  }

  100% {
    opacity: 1;
    transform: translate3d(0, 0, 0) rotateY(var(--tilt, 0deg));
  }
}
</style>
