<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { num, table, text, records, own } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'

/**
 * THE HOLOGRAM -- one screen, centred, and every verb this module has on it.
 *
 * THE OWNER, in three messages: "fait en sorte que cela passe pas par alt ce
 * serais en gros fait une touche qui ouvre un menu style halogram tous se passe
 * desus call resus contact etc plus de alt", then "le halo prend vrais le devant
 * de l'ecran", then "en plein centre".
 *
 * WHAT IT REPLACED, and why the replacement is not a straight port: this module
 * lived on the target eye. Eight rows -- answer, refuse, hang up, call, add,
 * share a contact, open the contacts, bring the card back. They worked. They
 * were also the wrong mechanism: ALT needs a body under the crosshair, and a
 * holocall is the thing you reach for when the person is NOT in front of you.
 * Answering one meant pointing at your own body first.
 *
 * THIS IS THE ONE VIEW IN THE MODULE THAT MAY BE PRESSED, and that is the whole
 * reason it is a separate surface. The incoming card and the live chip are on
 * `overlay`: `pointer-events: none` for their whole height, never focused, so a
 * call arriving can never take the mouse or stand between the player and what
 * they are aiming at. This one is on `interactive`, centred, in front and
 * focused, because the player opened it on a key, deliberately. A passive notice
 * that could steal input and a deliberate screen that could not would both be
 * the wrong way round.
 *
 * NOTHING HERE DECIDES ANYTHING. Every row names a player id and sends it; the
 * server judges the invite again and refuses it in its own words. A row is drawn
 * greyed with the reason the server ALREADY gave for it -- `refusal` comes off
 * the roster, worked out by the same function that judges the real invite -- so
 * the screen never offers something the next press would refuse.
 *
 * THE LISTS ARE NOT CACHED. Lua asks for a fresh roster on every open, because
 * who is connected, who is busy and who is close enough to hand a contact to are
 * facts with a shelf life of seconds.
 */

const { t } = useLocale()

interface Row {
  id: number
  /** The server's reference for this contact, for a delete. */
  ref: string
  name: string
  refusal: string | null
}

interface Recent {
  outcome: string
  name: string
}

const open = ref(false)
const contacts = ref<Row[]>([])
const recent = ref<Recent[]>([])

/** The call this player is on, the one ringing at them, and the one they placed. */
const call = ref<Payload | null>(null)
const invite = ref<Payload | null>(null)
const outgoing = ref<Payload | null>(null)

/** Which list is showing. Local: the screen's own state, never Lua's. */
const tab = ref<'contacts' | 'recent'>('contacts')

const onCall = computed(() => call.value !== null)
const ringing = computed(() => invite.value !== null)

/** A call this player placed that is still ringing on the other side. A
 *  contact request is not dialling, so it pops nothing. */
const dialing = computed(
  () => outgoing.value !== null && text(outgoing.value.kind) !== 'contact'
)

/**
 * WHO IS RINGING, AS THE SERVER NAMES THEM. The push carries `fromName`; the
 * page read `name`, which the server never sends, so every incoming call popped
 * the sphere with a `?` in it. `name` is still read second, for a payload built
 * by hand.
 */
const callerName = computed(() =>
  invite.value === null ? '?' : text(invite.value.fromName, text(invite.value.name, '?'))
)

/** Who this player is ringing out to. */
const calleeName = computed(() =>
  outgoing.value === null ? '?' : text(outgoing.value.toName, '?')
)

/** Who is on the call, as names, for the header. */
const participants = computed(() => {
  const held = call.value === null ? [] : records(call.value.participants)
  return held.map((row) => text(row.name, '?')).filter((name) => name !== '')
})

/**
 * The invite's kind decides which question is asked. A contact hand-over is not
 * a call and must not be answered with "Répondre": the owner asked for the share
 * to be "un input qui propose un yes or no", and this is where that lands.
 */
const inviteIsContact = computed(
  () => invite.value !== null && text(invite.value.kind) === 'contact'
)

function rowsOf(value: unknown): Row[] {
  return records(value)
    .map((row) => ({
      id: num(row.id),
      ref: text(row.ref),
      name: text(row.name, '?'),
      // `text()` answers '' for an absent field, and '' is not a refusal. The
      // absence has to survive as one, because it is what makes a row pressable.
      refusal: row.refusal === undefined || row.refusal === null ? null : text(row.refusal)
    }))
    // A contact who is not connected has no id and is still listed -- greyed
    // `offline` -- because a contact can be deleted, and a row nobody can see
    // is a row nobody can delete.
    .filter((row) => row.id > 0 || row.ref !== '')
}

// THE HANDSHAKE. It lived on the incoming card on the left, which is gone; Lua
// answers with this player's whole call state.
onMounted(() => {
  emit('opx:calls:ready', {})
})

useBridge('opx:calls:holo', (payload: Payload) => {
  guard('calls:holo', () => {
    open.value = payload.open === true
    contacts.value = rowsOf(payload.rows)
    recent.value = records(payload.recent).map((row) => ({
      outcome: text(row.outcome, 'missed'),
      name: text(row.name, '?')
    }))
    const live = table(payload.call)
    call.value = Object.keys(live).length > 0 ? live : null
    const ring = table(payload.invite)
    invite.value = Object.keys(ring).length > 0 ? ring : null
    if (text(payload.anchor) !== '') anchor.value = text(payload.anchor)
    if (text(payload.answerKey) !== '') answerKey.value = text(payload.answerKey)
    if (text(payload.declineKey) !== '') declineKey.value = text(payload.declineKey)
    const placed = table(payload.outgoing)
    outgoing.value = Object.keys(placed).length > 0 ? placed : null

    // A screen always opens on the contacts. It used to fall to a "nearby" tab
    // for a player with none, which was the right default while that tab was
    // the only way to make a first contact -- the eye does that now.
  }, undefined)
})

function close(): void {
  emit('opx:calls:close', {})
}

/* THE PAGE HOLDS 'calls' WHILE THE SCREEN IS OPEN, mirroring Lua's own
   `AcquireFocus('calls')` in modules/calls/client/view.lua. It did not, and Lua's
   `focus:set` reconcile (core/client/ui.lua) treats the page's announced stack as
   the truth: the next time any OTHER view released focus -- chat, a menu, the
   downed screen -- the page announced "nothing focused" and Lua wiped the calls
   entry with it. The hologram stayed drawn with no cursor and the keys back in the
   game. Same id as Lua's owner, so the reconcile keeps it; Escape asks Lua to close,
   and the release follows Lua's `open = false`, never the page's own guess. */
let release: (() => void) | undefined

watch(open, (isOpen) => {
  if (isOpen && release === undefined) {
    release = acquireFocus({ id: 'calls', onEscape: close })
  } else if (!isOpen && release !== undefined) {
    release()
    release = undefined
  }
})

onUnmounted(() => {
  // A focus held across an unmount leaves the player unable to move.
  release?.()
  release = undefined
})

function callRow(row: Row): void {
  if (row.refusal !== null) return
  emit('opx:calls:call', { id: row.id })
}

// `shareRow` stood here and sent `opx:calls:share`. Handing somebody a contact
// is back on the target eye, where it belongs: it is the one thing in this
// feature you do to a person standing in front of you. The seam still accepts
// `share`, because the eye row is what sends it now.

function accept(): void {
  emit('opx:calls:accept', {})
}

function decline(): void {
  emit('opx:calls:decline', {})
}

function hangUp(): void {
  emit('opx:calls:hangUp', {})
}

/** The row whose DELETE was pressed once and waits for the second press. A
    delete asks first, as every destroying row in this resource does. */
const confirming = ref<string | null>(null)

/* THE ARMED DELETE DOES NOT OUTLIVE WHAT THE PLAYER WAS LOOKING AT. Left armed across
   a close or a tab switch, the row came back reading "SURE?" and the next single
   press deleted the contact -- the confirmation had been given minutes earlier, for
   a screen that was no longer up. */
watch([open, tab], () => {
  confirming.value = null
})

function forgetRow(row: Row): void {
  if (row.ref === '') return
  if (confirming.value !== row.ref) {
    confirming.value = row.ref
    return
  }
  confirming.value = null
  emit('opx:calls:forget', { ref: row.ref })
}

function withdraw(): void {
  emit('opx:calls:withdraw', {})
}

/**
 * LITERAL KEYS, NOT BUILT ONES, and the suite is why. A catalogue check walks
 * this file for `t('calls...')` and asserts every one exists in both languages;
 * a key assembled from a prefix and a variable is invisible to it, so the first
 * missing line would reach a player as the word `calls.holo.tab.recent` printed
 * on a button. These three maps are that check's eyes.
 */
const TAB_KEY = {
  contacts: 'calls.holo.tab.contacts',
  recent: 'calls.holo.tab.recent'
} as const

const OUTCOME_KEY: Record<string, string> = {
  missed: 'calls.holo.outcome.missed',
  unanswered: 'calls.holo.outcome.unanswered',
  declined: 'calls.holo.outcome.declined',
  refused: 'calls.holo.outcome.refused'
}

/**
 * The refusal's own key. Nineteen of them, named in `Model.REASONS`, and the
 * suite already walks THAT list against both catalogues -- so this one is built
 * rather than listed, and deliberately not written as a `t('calls.error...')`
 * literal that would make the other check think it had found a key.
 */
function reasonKey(reason: string): string {
  return 'calls.error.' + reason
}

/**
 * WHETHER ANYTHING IS ON SCREEN, and the two reasons are different. `open` is
 * the player pressing the key: the whole projection, focused and pressable. The
 * other two are a call arriving or running -- "tu vas juste pop l'animation pas
 * le menu" -- so the sphere pops with the caller in it, says which keys answer
 * it, and takes nothing at all.
 */
const present = computed(
  () => open.value || ringing.value || onCall.value || dialing.value
)

/**
 * The two letters the sphere prints. They come off the payload rather than
 * being written here: a server that rebinds them in `config/calls.lua` must not
 * have its players told the wrong key, and a page that hardcoded `Y` would be a
 * second opinion about a configuration it cannot see.
 */
/**
 * WHERE THE PROJECTION SITS, as a name rather than a stylesheet. Lua settles it
 * against the one vocabulary in `lib/shared/anchors.lua` and sends the word; the
 * classes below are the nine it can be. The owner moved this by hand three times
 * before it was a setting.
 */
const anchor = ref('bottom-center')

const answerKey = ref('Y')
const declineKey = ref('X')

const shown = computed<Row[]>(() => contacts.value)
</script>

<template>
  <div v-if="present" class="holo op-ink" :class="['anchor-' + anchor, { live: !open }]">
    <!-- ── THE PROJECTOR ──────────────────────────────────────────────────
         "je souhaite vraiement un effect de holo 3d en cercle un delire plutot
         pousser que cela donne vraiement l'impression de l'utiliser de l'oeil".

         THE PLATE IS LAID BACK AND THE CONTENT STANDS UP, which is the whole of
         the 3D: one `perspective` on the wrapper, a disc rotated flat under it
         like a projector base, and the panel standing almost upright above it.
         Nothing here is an image and nothing is a filter -- the design system
         forbids a filter on anything that repaints, and there is a clock on this
         surface. Rings, gradients and one transform each.
    -->
    <div class="stage">
      <!-- The plate the projection stands on: three rings and one sweeping arc.
           The sweep is what makes it read as live rather than printed, and it is
           a `rotate` on a pseudo-element, which the compositor owns. -->
      <div class="disc" aria-hidden="true">
        <span class="ring r1"></span>
        <span class="ring r2"></span>
        <span class="ring r3"></span>
        <span class="sweep"></span>
      </div>

      <!-- The beam. One gradient and a clip, and it does most of the work of
           making the panel look PROJECTED rather than drawn. -->
      <div class="beam" aria-hidden="true"></div>

      <!-- ── THE SPHERE ALONE ────────────────────────────────────────────
           "tu vas juste pop l'animation pas le menu est dans la sphere tu vas
           ajouter les gens qui appel ou presnter un incoming call puis avec les
           prompt afficher y pour repondre x pour reffuser".

           A CALL ARRIVING OPENS NOTHING. There is no panel here, nothing to
           press and nothing focused -- the projection pops, the caller's name
           sits in it, and two letters say how to answer. A player who is
           driving or shooting is told and can decide without losing the
           keyboard, which is the whole reason the answer is a key and not a
           button.

           It replaces two views: a card on one side of the screen and a chip on
           the other. One projection, at the bottom, doing both.
      -->
      <div v-if="!open" class="passive">
        <p v-if="ringing" class="passive-who op-label">
          {{ callerName }}
        </p>
        <p v-else-if="onCall" class="passive-who op-label">
          {{ participants.join(', ') }}
        </p>
        <p v-else class="passive-who op-label">
          {{ calleeName }}
        </p>
        <!-- THE NAME ONCE. Dialling out with no call, the line above already
             says who: "Calling {name}..." under it printed it twice. The
             named line is for the one case it adds something -- on a call,
             asking a third, where the line above lists the people on it.
             A contact offer the same: the line above is the caller -- already
             whatever Lua lets this player know them as, a stranger included --
             so the offer under it is said without a name. -->
        <p class="passive-what op-eyebrow">
          {{ ringing
            ? (inviteIsContact ? t('calls.holo.contactOffer')
              : t('calls.holo.incoming'))
            : onCall
              ? (dialing ? t('calls.holo.calling', { name: calleeName }) : t('calls.holo.inCall'))
              : t('calls.holo.dialing') }}
        </p>
        <!-- THE KEYS, AS LETTERS. Read off the config the same way the rest of
             this surface reads its words, so a server that rebinds them is not
             telling its players the wrong thing. -->
        <div v-if="ringing" class="prompts">
          <span class="prompt">
            <b class="cap">{{ answerKey }}</b>
            {{ inviteIsContact ? t('calls.holo.yes') : t('calls.holo.answer') }}
          </span>
          <span class="prompt">
            <b class="cap">{{ declineKey }}</b>
            {{ inviteIsContact ? t('calls.holo.no') : t('calls.holo.refuse') }}
          </span>
        </div>
        <!-- HANGING UP IS ANSWERED THE SAME WAY: one letter in the sphere, the
             refuse key, nothing to open. While something rings out it
             withdraws that first -- on a call too -- and the word says so,
             because the key does exactly what is printed beside it. -->
        <div v-else class="prompts">
          <span class="prompt">
            <b class="cap">{{ declineKey }}</b>
            {{ outgoing !== null ? t('calls.holo.withdraw') : t('calls.holo.hangUp') }}
          </span>
        </div>
      </div>

      <!-- THE FRAME HOLDS THE TILT AND THE EDGES; THE PANEL INSIDE IT SCROLLS.
           The ring pulse used to animate `border-color` on the scrolling,
           3D-transformed panel itself, which repainted the whole projection on
           every frame for as long as a call rang (#113). The edges are now a
           layer of their own that never scrolls and never repaints: drawn once
           at 0.95, and the pulse is its `opacity` -- 0.4737 x 0.95 is the
           0.45 the edges rest at, so the alpha travels the same path as the
           old colour did, on the compositor. -->
      <div v-if="open" class="panel-frame" :class="{ 'is-ringing': ringing }">
        <section class="panel">
          <!-- NO PLATE ANYWHERE ON THIS SURFACE. The owner has asked for the
               background gone three times now, and a hologram with a slab behind
               it is a window. Legibility comes from light instead: the type
               carries its own glow and `.op-ink` holds it against the street,
               which is what every other plateless surface here leans on. -->
          <header class="head">
            <p class="eyebrow op-eyebrow">{{ t('calls.holo.eyebrow') }}</p>
            <h2 class="title op-label">{{ t('calls.holo.title') }}</h2>
            <button class="shut op-eyebrow" type="button" @click="close">
              {{ t('calls.holo.close') }}
            </button>
          </header>

          <!-- The ringing call is the one thing here with a clock running on it,
               so it sits above everything and the panel's edges pulse with it. -->
          <div v-if="ringing" class="ring-row">
            <p class="ring-who op-copy">
              {{ inviteIsContact
                ? t('calls.holo.sharing', { name: callerName })
                : t('calls.holo.ringing', { name: callerName }) }}
            </p>
            <div class="acts">
              <button class="act yes op-eyebrow" type="button" @click="accept">
                {{ inviteIsContact ? t('calls.holo.yes') : t('calls.holo.answer') }}
              </button>
              <button class="act no op-eyebrow" type="button" @click="decline">
                {{ inviteIsContact ? t('calls.holo.no') : t('calls.holo.refuse') }}
              </button>
            </div>
          </div>

          <div v-if="onCall" class="live-row">
            <p class="live-who op-copy">
              {{ t('calls.holo.live', { names: participants.join(', ') }) }}
            </p>
            <button class="act no op-eyebrow" type="button" @click="hangUp">
              {{ t('calls.holo.hangUp') }}
            </button>
          </div>

          <!-- WHAT IS RINGING OUT, and its own way back. Shown on a call too: a
               third person being asked to join is withdrawn here, while the live
               row's button above still ends the call itself. -->
          <div v-if="outgoing !== null" class="live-row">
            <!-- A contact offer is not a call: it read "Calling {name}..." here. -->
            <p class="waiting op-eyebrow">
              {{ dialing ? t('calls.holo.calling', { name: calleeName }) : t('calls.holo.offering') }}
            </p>
            <button class="act no op-eyebrow" type="button" @click="withdraw">
              {{ t('calls.holo.withdraw') }}
            </button>
          </div>

          <nav class="tabs">
            <button
              v-for="name in (['contacts', 'recent'] as const)"
              :key="name"
              class="tab op-eyebrow"
              :class="{ on: tab === name }"
              type="button"
              @click="tab = name"
            >
              {{ t(TAB_KEY[name]) }}
            </button>
          </nav>

          <ul v-if="tab !== 'recent'" class="rows">
            <li v-for="row in shown" :key="row.ref || row.id" class="row" :class="{ off: row.refusal !== null }">
              <span class="dot" aria-hidden="true"></span>
              <span class="who op-copy op-truncate">{{ row.name }}</span>
              <!-- THE REASON IS SHOWN, NOT MERELY OBEYED. A row that is simply
                   dark says the contact is unreachable and nothing else, and the
                   two commonest reasons both stop being true in a minute. -->
              <span v-if="row.refusal !== null" class="why op-eyebrow">
                {{ t(reasonKey(row.refusal)) }}
              </span>
              <template v-else>
                <button class="pill op-eyebrow" type="button" @click="callRow(row)">
                  {{ onCall ? t('calls.holo.add') : t('calls.holo.call') }}
                </button>
              </template>
              <button
                v-if="row.ref !== ''"
                class="pill op-eyebrow"
                type="button"
                @click="forgetRow(row)"
              >
                {{ confirming === row.ref ? t('calls.holo.forgetConfirm') : t('calls.holo.forget') }}
              </button>
            </li>
            <li v-if="shown.length === 0" class="empty op-copy">
              {{ t('calls.holo.noContacts') }}
            </li>
          </ul>

          <ul v-else class="rows">
            <li v-for="(row, at) in recent" :key="at" class="row off">
              <span class="dot" aria-hidden="true"></span>
              <span class="who op-copy op-truncate">{{ row.name }}</span>
              <span class="why op-eyebrow">
                {{ t(own(OUTCOME_KEY, row.outcome) ?? 'calls.holo.outcome.missed') }}
              </span>
            </li>
            <li v-if="recent.length === 0" class="empty op-copy">
              {{ t('calls.holo.noRecent') }}
            </li>
          </ul>
        </section>
        <span class="panel-edges" aria-hidden="true"></span>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   DEAD CENTRE, IN FRONT, AND PROJECTED -- "le halo prend vrais le devant de
   l'ecran", "en plein centre", "un effect de holo 3d en cercle un delire plutot
   pousser".

   WHAT THIS IS NOT: a panel with a background. The first version was exactly
   that, and a slab is what stops a hologram reading as one. Everything below
   builds legibility out of LIGHT instead -- the type carries its own glow, and
   the disc and the beam give the eye somewhere to sit the panel.

   AND THE CLASSES ARE REAL ONES. The first version reached for `.op-title` and
   `.op-micro`, neither of which exists anywhere in the design system, so every
   label on this screen rendered with no type preset at all. `surface.css`
   defines five: `.op-label`, `.op-value`, `.op-eyebrow`, `.op-copy`,
   `.op-truncate`. Those are what is used here.

   NO FILTERS. `design-system/shapes.css` says never to put one on something
   that repaints, and this surface has a clock on it. Every effect is a
   gradient, a border-radius or a transform, and the only animation is a
   `rotate` on a pseudo-element.
   ========================================================================== */
.holo {
  position: absolute;
  inset: 0;
  display: flex;
  /* AT THE BOTTOM, NOT THE MIDDLE. The owner asked for centre first and then
     corrected it twice -- "mets le en bas" -- and the reason shows the moment
     you use it: this is a projection you glance at while doing something else,
     and the middle of the screen is where the thing you are doing is. */
  align-items: flex-end;
  justify-content: center;
  /* FLUSH. "vraiemen coller en bas la il y a un espace encore entre le bas et le
     debut du holo" -- there was a screen inset here, and the disc sat another
     8% up inside the stage on top of it. A projector plate belongs ON the
     bottom edge, with its far rim running off it, the way one would if it were
     really standing on the floor in front of the player. */
  padding-bottom: 0;
  /* The layer stays transparent to the pointer; only the panel takes it. */
  pointer-events: none;
  /* THE ONE PERSPECTIVE. Everything inside is laid out against it, which is
     what makes the disc read as lying under the panel rather than as an ellipse
     drawn behind it. */
  perspective: 900px;
  perspective-origin: 50% 46%;
}

/* --- the nine positions ----------------------------------------------------
   The vocabulary in `lib/shared/anchors.lua`, one class each. Lua sends the
   name; this is the only place it becomes geometry.

   The projection is laid out with `align-items` and `justify-content` on the
   full-screen wrapper rather than with `position` on the pane, so a position
   change never touches the 3D inside it: the disc, the beam and the panel keep
   the same relationship to each other wherever the whole thing sits. */
.anchor-top-left {
  align-items: flex-start;
  justify-content: flex-start;
}

.anchor-top-center {
  align-items: flex-start;
  justify-content: center;
}

.anchor-top-right {
  align-items: flex-start;
  justify-content: flex-end;
}

.anchor-left {
  align-items: center;
  justify-content: flex-start;
}

.anchor-center {
  align-items: center;
  justify-content: center;
}

.anchor-right {
  align-items: center;
  justify-content: flex-end;
}

.anchor-bottom-left {
  align-items: flex-end;
  justify-content: flex-start;
}

.anchor-bottom-center {
  align-items: flex-end;
  justify-content: center;
}

.anchor-bottom-right {
  align-items: flex-end;
  justify-content: flex-end;
}

/* A projection standing on the floor belongs ON the bottom edge; one anchored
   anywhere else needs the screen inset back, or it touches the frame. */
.holo:not([class*='anchor-bottom']) {
  padding: var(--op-inset-y) var(--op-inset-x);
}

.stage {
  position: relative;
  display: flex;
  align-items: flex-end;
  justify-content: center;
  width: min(560px, calc(100vw - var(--op-inset-x) * 2));
  height: min(460px, calc(100vh - var(--op-inset-y)));
  transform-style: preserve-3d;
  animation: op-holo-rise 220ms ease-out both;
}

/* --- the projector plate -------------------------------------------------- */
.disc {
  position: absolute;
  left: 50%;
  /* Below the edge, so the near rim is what the player sees and the far one
     runs off the bottom of the screen. */
  bottom: -9%;
  width: 380px;
  height: 380px;
  margin-left: -190px;
  transform: rotateX(74deg);
  transform-style: preserve-3d;
}

.ring {
  position: absolute;
  inset: 0;
  border: 1px solid rgba(var(--op-red-rgb), 0.35);
  border-radius: 50%;
}

.r2 {
  inset: 14%;
  border-color: rgba(var(--op-red-rgb), 0.22);
}

.r3 {
  inset: 30%;
  border-color: rgba(var(--op-red-rgb), 0.5);
  box-shadow: 0 0 26px rgba(var(--op-red-rgb), 0.28);
}

.sweep {
  position: absolute;
  inset: 4%;
  border-radius: 50%;
  background: conic-gradient(
    from 0deg,
    rgba(var(--op-red-rgb), 0) 0deg,
    rgba(var(--op-red-rgb), 0) 250deg,
    rgba(var(--op-red-rgb), 0.24) 320deg,
    rgba(var(--op-red-rgb), 0) 360deg
  );
  animation: op-holo-sweep 5.5s linear infinite;
}

@keyframes op-holo-sweep {
  to {
    transform: rotate(360deg);
  }
}

/* --- the beam ------------------------------------------------------------- */
.beam {
  position: absolute;
  left: 50%;
  bottom: -4%;
  width: 300px;
  height: 260px;
  margin-left: -150px;
  background: linear-gradient(
    to top,
    rgba(var(--op-red-rgb), 0.16),
    rgba(var(--op-red-rgb), 0.04) 45%,
    transparent 78%
  );
  clip-path: polygon(38% 100%, 62% 100%, 96% 0%, 4% 0%);
  transform: translateZ(1px);
}

/* --- the panel ------------------------------------------------------------ */
/* The frame is what stands in the stage: the tilt, the size and the edges. It
   never scrolls, so the edge layer in it is painted once and then only ever
   composited. A column flex box, so the panel inside shrinks to the frame's
   max-height and scrolls instead of overflowing it. */
.panel-frame {
  position: relative;
  display: flex;
  flex-direction: column;
  box-sizing: border-box;
  width: 100%;
  max-height: 78%;
  margin-bottom: 14%;
  transform: rotateX(6deg) translateZ(40px);
}

.panel {
  position: relative;
  box-sizing: border-box;
  flex: 0 1 auto;
  min-height: 0;
  width: 100%;
  padding: var(--op-space-3);
  overflow: auto;
  /* Scrolls like every other list on the surface: by the wheel, with no OS
     scrollbar drawn across the projection. */
  scrollbar-width: none;
  /* THE ONLY ELEMENT ON THIS SURFACE THAT TAKES THE POINTER. A click beside it
     goes to the world. */
  pointer-events: auto;
  /* The projection's own edge, instead of a plate: a hairline down each side
     and a scanline wash across it. The hairlines are `.panel-edges`; the
     border stays, transparent, so the scanlines still run under them and the
     content keeps its place. */
  border-left: 1px solid transparent;
  border-right: 1px solid transparent;
  background: repeating-linear-gradient(
    to bottom,
    rgba(var(--op-red-rgb), 0.05) 0 1px,
    transparent 1px 3px
  );
}

.panel::-webkit-scrollbar {
  width: 0;
  height: 0;
}

/* The hairlines, over the panel's transparent border. Drawn at the ring's peak
   alpha and held at 0.45 / 0.95 = 0.4737 of it at rest. */
.panel-edges {
  position: absolute;
  inset: 0;
  pointer-events: none;
  border-left: 1px solid rgba(var(--op-red-rgb), 0.95);
  border-right: 1px solid rgba(var(--op-red-rgb), 0.95);
  opacity: 0.4737;
}

.panel-frame.is-ringing .panel-edges {
  animation: op-holo-pulse 1.6s ease-in-out infinite;
}

@keyframes op-holo-pulse {
  0%,
  100% {
    opacity: 0.4737;
  }
  50% {
    opacity: 1;
  }
}

/* --- the sphere alone ------------------------------------------------------
   What a call arriving looks like: the projection, the name, and two letters.
   No panel, nothing pressable, nothing focused. */
.passive {
  position: relative;
  margin-bottom: 14%;
  text-align: center;
  /* Said again here although the layer already says it: this is drawn over
     whatever the player is aiming at, and it must never take the pointer. */
  pointer-events: none;
}

.passive-who {
  margin: 0;
  color: var(--op-red);
  text-shadow: var(--op-ink), 0 0 14px var(--op-red-glow);
}

.passive-what {
  margin: var(--op-space-1) 0 0;
  color: var(--op-text-faint);
}

.prompts {
  display: flex;
  gap: var(--op-space-3);
  justify-content: center;
  margin-top: var(--op-space-2);
  color: var(--op-text-faint);
}

.prompt {
  display: inline-flex;
  align-items: center;
  gap: var(--op-space-1);
}

/* The key itself, drawn as a key. */
.cap {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 18px;
  padding: 1px 4px;
  border: 1px solid rgba(var(--op-red-rgb), 0.55);
  color: var(--op-red);
  font-weight: 700;
}

.head {
  display: grid;
  grid-template-columns: 1fr auto;
  align-items: baseline;
  gap: var(--op-space-1);
  margin-bottom: var(--op-space-3);
  padding-bottom: var(--op-space-2);
  border-bottom: 1px solid rgba(var(--op-red-rgb), 0.3);
}

.eyebrow {
  grid-column: 1;
  margin: 0;
  color: var(--op-text-faint);
}

.title {
  grid-column: 1;
  margin: 0;
  color: var(--op-red);
  /* The type's own light, and this is what replaces the plate: a letter that
     emits is legible over a bright street with nothing behind it. */
  text-shadow: var(--op-ink), 0 0 12px var(--op-red-glow);
}

.shut {
  grid-column: 2;
  grid-row: 1 / span 2;
  border: 0;
  background: none;
  color: var(--op-text-faint);
  cursor: pointer;
}

.shut:hover {
  color: var(--op-red);
}

.ring-row,
.live-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--op-space-2);
  margin-bottom: var(--op-space-2);
  padding: var(--op-space-2) 0;
  border-bottom: 1px solid rgba(var(--op-red-rgb), 0.2);
}

.ring-who,
.live-who {
  margin: 0;
  min-width: 0;
}

.acts {
  display: flex;
  gap: var(--op-space-1);
}

.act {
  border: 1px solid rgba(var(--op-red-rgb), 0.5);
  padding: var(--op-space-1) var(--op-space-2);
  background: none;
  color: var(--op-red-text);
  cursor: pointer;
}

.act:hover {
  border-color: var(--op-red);
  color: var(--op-red);
  box-shadow: 0 0 14px rgba(var(--op-red-rgb), 0.3);
}

.act.no {
  color: var(--op-text-faint);
}

.waiting {
  margin: 0 0 var(--op-space-2);
  color: var(--op-text-faint);
}

.tabs {
  display: flex;
  gap: var(--op-space-3);
  margin-bottom: var(--op-space-2);
}

.tab {
  border: 0;
  border-bottom: 1px solid transparent;
  padding: var(--op-space-1) 0;
  background: none;
  color: var(--op-text-faint);
  cursor: pointer;
}

.tab:hover:not(.on) {
  color: var(--op-red-text);
  border-bottom-color: rgba(var(--op-red-rgb), 0.4);
}

.tab.on {
  border-bottom-color: var(--op-red);
  color: var(--op-red);
  text-shadow: var(--op-ink), 0 0 10px var(--op-red-glow);
}

.rows {
  margin: 0;
  padding: 0;
  list-style: none;
}

.row {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  padding: var(--op-space-1) 0;
  border-bottom: 1px solid rgba(var(--op-red-rgb), 0.14);
}

/* The reachable marker: lit for a row that can be pressed, dark for one that
   cannot. The only thing on a row that says so at a glance. */
.dot {
  flex: none;
  width: 5px;
  height: 5px;
  border-radius: 50%;
  background: var(--op-red);
  box-shadow: 0 0 8px var(--op-red-glow);
}

.row.off {
  color: var(--op-text-faint);
}

.row.off .dot {
  background: rgba(var(--op-red-rgb), 0.25);
  box-shadow: none;
}

.who {
  flex: 1;
  min-width: 0;
}

/* A REASON IS A SENTENCE, and in French a long one ("Votre liste de contacts est
   pleine..."). It may wrap -- cutting it would hide why the row is dark -- but it
   takes at most a little over half the row, so the name keeps the rest, and its
   lines get a leading of their own: the eyebrow's line-height of 1 set the wrapped
   lines touching. */
.why {
  flex: 0 1 auto;
  max-width: 55%;
  line-height: 1.3;
  text-align: right;
  color: var(--op-text-faint);
}

/* A button label never wraps: "SÛR ?" broke at its space and stood two lines tall. */
.pill,
.act {
  flex: none;
  white-space: nowrap;
}

.pill {
  border: 1px solid rgba(var(--op-red-rgb), 0.4);
  padding: 2px var(--op-space-2);
  background: none;
  color: var(--op-red-text);
  cursor: pointer;
}

.pill:hover {
  border-color: var(--op-red);
  color: var(--op-red);
  box-shadow: 0 0 12px rgba(var(--op-red-rgb), 0.28);
}

.empty {
  padding: var(--op-space-3) 0;
  color: var(--op-text-faint);
}

/* A projection does not fade in from nowhere: it rises off the plate. */
@keyframes op-holo-rise {
  from {
    opacity: 0;
    transform: translateY(10px) scale(0.98);
  }
  to {
    opacity: 1;
    transform: none;
  }
}

/* A player who has asked the system to stop moving things gets a still
   hologram, not a broken one. */
@media (prefers-reduced-motion: reduce) {
  .sweep,
  .panel-frame.is-ringing .panel-edges,
  .stage {
    animation: none;
  }
}
</style>
