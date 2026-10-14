<script setup lang="ts">
import { computed, ref, shallowRef } from 'vue'
import { report } from '@/bridge/diag'
import { bool, list, num, table, text, records } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'

/**
 * THE NAME TAGS -- who is standing there, drawn over their head.
 *
 * TWO CHANNELS, AND THEY RUN AT VERY DIFFERENT SPEEDS. That is the whole shape of
 * this file:
 *
 *   `opx:admin:tags`   WHAT to draw. One payload when the frame changes, which is
 *                      a handful of times a minute: a player walked into range, a
 *                      name arrived, the operator switched them off.
 *   `open77:anchors`   WHERE to draw it. The host projects every anchor on every
 *                      game frame and publishes the batch to this surface, so a
 *                      tag follows a running body without anything crossing the
 *                      Lua tick.
 *
 * They are joined by the ANCHOR ID, which `modules/admin/client/tagsview.lua`
 * puts on every row. A row whose anchor is absent from the batch is NOT DRAWN:
 * the host's own words are that the batch is the complete set and an id missing
 * from it is behind the camera, out of the distance band, or its body is not
 * streamed. Holding the last coordinate would leave a tag pinned to the sky where
 * someone used to be.
 *
 * THE COORDINATES ARE NORMALISED, 0..1, top-left origin -- the platform's
 * convention for every screen coordinate it hands a page. They are multiplied by
 * the viewport here and never stored in pixels: the surface is 1920x1080 and the
 * game window is not.
 *
 * NOTHING HERE TAKES A POINTER OR THE KEYBOARD. It is on the overlay layer, which
 * is `pointer-events: none` for the whole layer, and this file does not re-enable
 * it -- a name tag that captured the keyboard would stop the player moving.
 *
 * -- DESIGN PASS 02 -----------------------------------------------------------
 *
 * A MARKER AND SOME TYPE. An id square on the left, drawn by augmented-ui with
 * the chamfer and the lit ground every control in the runtime wears, and the
 * names to the right of it wearing nothing at all.
 *
 * THE NAMES USED TO HAVE A PLATE and it has been taken off, on the owner's
 * instruction and for a reason that holds: nine tags on a street corner were
 * nine filled rectangles over the world, and the thing making the lettering
 * legible was never the ground -- it was the ink shadow on `.tag`, which is
 * still there and whose own comment always said so. Rule 2 of the contract
 * gives a closed box to what can be pressed; nothing on this layer can be
 * pressed. The square keeps its box because a square with an id in it IS a
 * marker. The names beside it are type.
 *
 * The square is centred against the column rather than sitting on its first
 * line. It rode the top edge while there was a plate for its corners to break;
 * with no edge to meet, a marker beside a block of type sits level with the
 * block's middle.
 *
 * It is NOT tilted, and that needs no argument: a tag is pinned to a body in the
 * world, and the world is already supplying its perspective.
 *
 * THREE NAMES, ONE PER LINE. They were on one line until the owner asked for the
 * column, and the column is the better shape for a reason worth keeping: three
 * runs abreast make a tag as wide as a body is tall, and at any distance the
 * whole thing is a smear with a name somewhere in it. Stacked, a tag is the width
 * of its widest run, and the eye reads down it the way it reads a label.
 *
 * They are still not three equal things, and the RANKING is what stops a column
 * from reading as a list of three addresses. It is carried by three dimensions at
 * once rather than by size alone:
 *
 *   THE CHARACTER   display face, uppercase, the brightest red. It is what the
 *                   city calls this person and it is the only run meant to be read
 *                   at distance. Everything else is for somebody who has already
 *                   walked up.
 *   THE ACCOUNT     mono, smaller, dimmer, and NOT uppercased -- an account name is
 *                   typed by its owner and casing is part of it.
 *   THE CITIZEN ID  mono, smallest, tracked wide, dimmest. It is a code and it is
 *                   read one symbol at a time, which is what the tracking is for.
 *
 * THE LINE BREAK IS THE SEPARATOR, and nothing is drawn on top of it. On one
 * line the runs were divided by a 1px hairline at 45% height -- a pause rather
 * than a glyph, because a bullet or a slash would be a fourth thing to read at a
 * name's weight. Turned on its side for a column that rule becomes a full-width
 * hairline, which reads as the plate being divided into CELLS: exactly what the
 * vertical one was shaped to avoid. So it is gone rather than rotated. This
 * surface still has no punctuation on it anywhere.
 *
 * A RUN THAT IS EMPTY DRAWS NOTHING -- a tag over somebody still loading is the
 * name and the square, and the plate shrinks back to the one-line strip it was.
 *
 * `TAGS.COLORS` IN `config/admin.lua` IS NOT READ. It is `#F2F6F8` / `#FCEE0A` /
 * `#22D8E2` / `#0A1220`: the pass-01 palette, and `.op-theme-city` turns the
 * accent Night City yellow. Pass 02 is one hue and bans both. The fields still
 * cross the bridge and still have their config entries -- the same standing this
 * tree gives `payload.eyebrow` in `HudInfo.vue` and `row.hold` in
 * `PromptsRoot.vue` -- because a page changing its mind does not change Lua's
 * contract. If an operator ever needs the colour back it is a palette on `.tags`,
 * not four literals through the wire.
 */

interface Row {
  anchor: string
  playerId: number
  /** THE CHARACTER, or the account when no character is loaded. Never empty: a
      row that yielded no name at all is filtered out before it gets here. */
  name: string
  /** THE ACCOUNT playing that character, and empty precisely when `name` is
      already it -- Lua decides that, so this page never has to. */
  user: string
  /** The character's public id, `4A7-KM9C`. Empty before a character loads. */
  citizenId: string
  staff: boolean
  /** The state half's own distance fade, already rounded to a tenth. */
  alpha: number
}

/** Where the host says an anchor is, in normalised viewport coordinates. */
interface Spot {
  x: number
  y: number
}

/**
 * Metres in front of the camera a tag has to be to be drawn at all.
 *
 * Half a metre is inside anybody's own head and outside everybody else's. It is
 * the one number that separates "my own tag in first person", which must never be
 * drawn, from every legitimate tag including someone standing against you.
 */
const MIN_DEPTH = 0.5

/** Whether the temporary batch probe below has already fired. Once per page load:
    the diagnostic relay is capped, and a probe on a per-frame channel would spend
    the whole budget in a second and drop the next real failure. */
let probed = false

const rows = shallowRef<Row[]>([])
const spots = shallowRef<Map<string, Spot>>(new Map())

/** `TAGS.TECHNICAL`: whether the id square is drawn at all. */
const technical = ref(true)
/** `TAGS.USERNAME` and `TAGS.CITIZEN`: the two trailing runs of the line. Each is
    a config switch AND a per-row fact, and both have to be true to draw -- an
    operator who turned the account off gets no account, and a body with no
    character loaded has no account to show beside a name that IS the account. */
const showUser = ref(true)
const showCitizen = ref(true)
/** The word a staff badge carries, localised by Lua. */
const staffLabel = ref('')

/**
 * The tags to draw: a row and a live projection for it, in one object.
 *
 * Built as one computed rather than resolved in the template so the `v-for` has a
 * stable array to key on, and so a row with no projection costs one lookup rather
 * than a rendered element that is then positioned off-screen.
 */
const drawn = computed(() =>
  rows.value
    .map((row) => {
      const spot = spots.value.get(row.anchor)
      return spot ? { row, spot } : null
    })
    .filter((entry): entry is { row: Row; spot: Spot } => entry !== null)
)

/**
 * Where one tag goes, as a TRANSFORM and not as `left` / `top`.
 *
 * The first version set both as percentages, and it is what the owner saw as the
 * tag "teleporting" from the page's side: `left` and `top` are layout, so every
 * projection -- sixty a second, per tag -- put the element through layout, paint
 * and composite, and the browser coalesces what it cannot keep up with. That is
 * the stutter. A `translate3d` is composited: it moves an existing layer and
 * costs neither layout nor paint, which is the same reason every moving bar on
 * this surface is a `scaleX` rather than a width.
 *
 * The anchor's own offset -- centred on the head, sitting just above it -- is the
 * SECOND translate and is in the element's own percentages, so it follows the
 * tag's size however long the name is. Order matters: the pixel move first, then
 * the self-relative one.
 *
 * Pixels rather than percentages because a transform percentage is a share of the
 * ELEMENT, not of the surface. The surface is a fixed 1920x1080 page, so
 * `innerWidth` is a constant the compositor never has to re-measure.
 */
function styleFor(entry: { row: Row; spot: Spot }): Record<string, string> {
  const x = Math.round(entry.spot.x * window.innerWidth)
  const y = Math.round(entry.spot.y * window.innerHeight)
  return {
    transform: `translate3d(${x}px, ${y}px, 0) translate(-50%, -100%)`,
    opacity: String(entry.row.alpha)
  }
}

useBridge('opx:admin:tags', (payload: Payload) => {
  switch (text(payload.kind)) {
    case 'config':
      technical.value = bool(payload.technical, true)
      showUser.value = bool(payload.showUser, true)
      showCitizen.value = bool(payload.showCitizen, true)
      staffLabel.value = text(payload.staffLabel)
      break
    case 'rows':
      rows.value = records(payload.rows)
        .map((raw) => ({
          anchor: text(raw.anchor),
          playerId: Math.round(num(raw.playerId)),
          name: text(raw.name),
          user: text(raw.user),
          citizenId: text(raw.citizenId),
          staff: raw.staff === true,
          // A missing fade is a visible tag, not an invisible one: the state half
          // sends it on every row and a payload that lost it should still draw.
          alpha: Math.max(0, Math.min(1, num(raw.alpha, 1)))
        }))
        .filter((row) => row.anchor !== '' && row.name !== '')
      break
    case 'hide':
      rows.value = []
      break
  }
})

/**
 * The projection batch, straight from the host.
 *
 * NOT AN `opx:` CHANNEL. `open77:anchors` is the platform's own name and the
 * bridge passes it through untouched -- this is the one channel on the page that
 * nothing in this runtime publishes.
 *
 * THE SHAPE IS READ DEFENSIVELY, and deliberately so. The host documents the
 * batch as the complete set for the surface and the coordinates as normalised
 * viewport ones; it does not document whether an entry carries `screen.x` or a
 * bare `x`, and `Open77.anchors.list` answers with the former while a batch is
 * cheaper as the latter. Both are accepted, the id is taken from `id` or
 * `anchor`, and an entry that yields neither is skipped rather than drawn at the
 * top-left corner.
 */
useBridge('open77:anchors', (payload: Payload) => {
  const batch = list<unknown>(payload.anchors)

  // TEMPORARY INSTRUMENT. The batch's shape is the one thing about this file that
  // was written from the prose rather than from a payload -- the host documents
  // the batch as "the complete set for that surface" and documents the
  // coordinates, but not which key the list arrives under or what an entry is
  // called. This says what actually landed, once, and reaches the server log
  // through `opx:diag`. Remove it the session the tags are confirmed drawing.
  if (!probed) {
    probed = true
    const first = batch.length > 0 ? table(batch[0]) : {}
    report(
      `keys=${Object.keys(payload).join('|')} n=${batch.length}` +
        ` entry=${Object.keys(first).join('|')}` +
        ` screen=${Object.keys(table(first.screen)).join('|')}`,
      'tags anchor batch'
    )
  }

  const next = new Map<string, Spot>()

  for (const value of batch) {
    const entry = table(value)
    const id = text(entry.id) || text(entry.anchor)
    if (id === '') continue

    // `onScreen` is the host's own cull. An entry that says false is behind the
    // camera or off the edge, and a tag there is a tag on nobody.
    if (entry.onScreen === false) continue

    const screen = table(entry.screen)
    const x = num(screen.x, num(entry.x, -1))
    const y = num(screen.y, num(entry.y, -1))
    if (x < 0 || y < 0) continue

    // TOO CLOSE TO BE A HEAD IN FRONT OF YOU. This is the first-person case for
    // the operator's own tag: the head is where the camera is, so the anchor
    // projects to the middle of the screen at arm's length, and a name tag pinned
    // over the crosshair is the one thing this surface must never do.
    //
    // It is a cull on DEPTH -- metres in front of the camera, which the host
    // sends with the projection -- and not on the perspective mode, because the
    // mode is a guess that answers nil on a client that cannot be asked while the
    // depth is a measurement that is always there. It costs nothing on a build
    // that sends no depth: absent, it is not a reason to hide anything.
    const depth = num(screen.depth, num(entry.depth, -1))
    if (depth >= 0 && depth < MIN_DEPTH) continue

    next.set(id, { x, y })
  }

  spots.value = next
})
</script>

<template>
  <div class="tags">
    <!-- Keyed on the ANCHOR and not the player id: an anchor is re-pointed when a
         body respawns, so the element survives exactly as long as the tag does. -->
    <div v-for="entry in drawn" :key="entry.row.anchor" class="tag" :style="styleFor(entry)">
      <span
        v-if="technical"
        class="id"
        :class="{ staff: entry.row.staff }"
        data-augmented-ui="tr-clip border"
      >{{ entry.row.playerId }}</span>
      <!-- NO FRAME AND NO GROUND on this one, which is why it carries no
           `data-augmented-ui`. It is not a control and never was -- rule 2 of
           the contract gives a closed box to things you can press, and nothing
           on this layer can be pressed. The square keeps its box because a
           square with an id in it IS a marker; the names beside it are type. -->
      <span class="plate" :class="{ staff: entry.row.staff, bare: !technical }">
        <!-- ONE RUN PER LINE. It used to be one line with 1px rules between the
             runs, and the rules are gone with the change rather than turned on
             their side: a horizontal hairline across a stacked plate reads as
             the plate being divided into cells, which is the exact thing the
             old vertical rule was shaped to avoid. Stacked, the line break IS
             the pause, and a separator on top of it is punctuation for a gap
             that is already there. -->
        <span class="name">{{ entry.row.name }}</span>

        <span v-if="showUser && entry.row.user" class="user op-eyebrow">{{ entry.row.user }}</span>

        <span v-if="showCitizen && entry.row.citizenId" class="cid">
          {{ entry.row.citizenId }}
        </span>

        <span v-if="entry.row.staff && staffLabel" class="badge">{{ staffLabel }}</span>
      </span>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   DESIGN PASS 02 -- RED, OUTLINED. The name tags' half of it.

   NOT TILTED, and it is the one surface where that needs no argument: a tag is
   pinned to a body in the world and the world is already supplying its
   perspective. A `rotateY` on top of that is a second, disagreeing one.

   THE SHAPE THE OWNER ASKED FOR: "a square on the left with the id, then to the
   right of the square -- letting the square's corners stick out a little -- the
   player's name". So the square is TALLER than the plate beside it and sits over
   its leading edge: four corners break the plate's outline, which is what makes
   the pair read as one object with a marker on it rather than as two boxes that
   happen to touch.
   ========================================================================== */

.tags {
  position: absolute;
  inset: 0;
  /* Inherited by every tag under it: the layer is already inert, and this says
     so locally as well, because a tag is the one thing on the overlay that sits
     directly over what the player is aiming at. */
  pointer-events: none;
}

.tag {
  position: absolute;
  /* The origin the transform moves FROM. Both are zero and neither is ever
     written again: the whole position is the transform, which is what keeps a tag
     off the layout path. */
  left: 0;
  top: 0;
  display: flex;
  /* THE SQUARE IS CENTRED AGAINST THE WHOLE COLUMN. It sat on the first line
     while the names had a plate behind them, because the square's job was then
     to break that plate's leading edge and the edge started at the top. With
     the plate gone there is no edge to meet: the square is a marker beside a
     block of type, and a marker beside a block sits level with its middle. */
  align-items: center;
  white-space: nowrap;

  /* THE SMOOTHING, and it is worth being exact about what it is for.

     The projection is now per frame on both sides -- the host projects an entity
     anchor every frame, and `SetTick` re-points the local one every frame -- so
     this is not covering for a slow update. It covers the frames the page does
     NOT get one: a dropped batch, a frame the compositor skipped, a body the
     server re-streamed. Without it each of those is a visible jump, because the
     tag lands exactly where it is told and nowhere in between.

     70ms LINEAR, and both parts are chosen. Linear because an eased transition
     re-eases from a standstill on every new value and reads as rubber; linear
     just draws the line. 70ms because it is about four frames -- long enough to
     bridge a gap, short enough that the tag is never visibly behind the head it
     belongs to. Anything past ~120ms and the tag swims.

     `opacity` rides the same transition: it is the distance fade, which Lua
     rounds to a tenth precisely so it steps rather than streams. */
  transition:
    transform 70ms linear,
    opacity var(--op-dur-fast) linear;

  /* It is the one thing on this surface that moves every frame, so it says so:
     the compositor gives it a layer up front instead of promoting it on the
     first move and dropping it on every pause. */
  will-change: transform;

  /* Declared once and inherited by both halves. Even with a ground under the
     lettering, a tag is the text on this page most likely to be read against a
     blown-out sky. */
  text-shadow:
    0 1px 2px rgba(0, 0, 0, 0.95),
    0 0 9px rgba(0, 0, 0, 0.8);

  /* The fade's own transition is declared with the movement above -- one
     `transition` per rule, or the second silently replaces the first. */
}

/* =============================================================================
   THE ID SQUARE -- the marker. It is the element that stands proud: everything
   about it is a size, and the sizes are what make the corners break the plate.
   ========================================================================== */
.id {
  position: relative;
  /* OVER the plate, so the square's own outline is unbroken and the plate's is
     the one that is interrupted. The other way round reads as the square being
     behind a window. */
  z-index: 1;
  flex: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  box-sizing: border-box;
  min-width: 26px;
  height: 26px;
  padding: 0 4px;

  font: 700 var(--op-fs-label) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-label);
  font-variant-numeric: tabular-nums;
  color: var(--op-red);

  /* The lit ground and the full-red edge: a square with an id in it is the one
     part of a tag that is an instrument. The cut is the house small one, which
     is what the 6px `border-image-width` on the old sprite worked out to. */
  --aug-tr: var(--op-cut-sm);
  --aug-border-bg: var(--op-red);
  --aug-border-all: 2.4px;
  background: var(--op-plate-lit);
}

/* =============================================================================
   THE NAME PLATE -- shorter than the square by 3px top and bottom, and pulled
   under it by 6px. Those two numbers ARE the effect the owner described: the
   square's four corners sit outside the plate's outline on every side that
   matters, and the plate's leading edge disappears behind it.
   ========================================================================== */
/* A COLUMN, NOT A ROW, and the height goes with it. The plate used to be a
   fixed 20px strip holding name, account and id side by side, which reads well
   for one short name and badly for everything else: three runs on one line make
   a tag as wide as the body is tall, and at any distance the whole thing is a
   smear. Stacked, the tag is the width of its widest run and the eye reads down
   it the way it reads a label.

   `align-items: flex-start` so the runs share a left edge -- centred, the three
   lines would each start somewhere different and the column would have no spine
   to read down. */
/* TYPE, NOT A BOX. The ground and the outline are gone: what is left is three
   lines of lettering held by the ink shadow declared on `.tag`, which was
   already carrying them ("even with a ground under the lettering, a tag is the
   text on this page most likely to be read against a blown-out sky"). The
   shadow was the thing making them legible; the plate was making them heavy.
   Nine tags on a street corner were nine filled rectangles over the world.

   With no outline there is nothing for the square's corners to break, so the
   overlap goes with it -- the `-6px` pull and the padding that paid it back
   were both in service of a frame that is no longer drawn. What remains is one
   gap between the marker and the words. */
.plate {
  position: relative;
  display: inline-flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 2px;
  box-sizing: border-box;
  padding-left: var(--op-space-2);
}

/* With no square there is nothing to tuck under, and the plate is the whole tag:
   it takes the padding back and stands on its own. */
/* With no square there is no gap to leave for one. */
.plate.bare {
  padding-left: 0;
}

.name {
  font: 700 var(--op-fs-meta) / 1 var(--op-font-display);
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--op-red-text);
}

/* THE ACCOUNT. Mono, because it is an identifier somebody typed rather than a
   name somebody was given, and the mono face is this tree's whole convention for
   that. NOT uppercased, for the same reason: the casing belongs to its owner. */
.user {
  /* `.op-eyebrow` MINUS ITS UPPERCASE, and that is the whole of what is left
     here: the role carried the face and the tracking, and the one deviation is
     spelled out rather than being the accident of a hand-written copy. */
  text-transform: none;
  color: var(--op-red-idle);
}

/* THE CITIZEN ID. Read one symbol at a time -- its alphabet is chosen so no two
   symbols read alike -- so it is tracked wider than anything else on the tag and
   set in tabular figures, which is what keeps `4A7-KM9C` from jittering as the
   roster changes under it. */
.cid {
  font: 700 var(--op-fs-micro) / 1 var(--op-font-mono);
  letter-spacing: 0.12em;
  font-variant-numeric: tabular-nums;
  color: var(--op-red-idle);
  opacity: 0.8;
}

/* =============================================================================
   STAFF -- WHITE-HOT, AND NOT A REDDER RED. Rule 4 of the contract, the same
   call the gauges and the chat's refusals make: red is this runtime's voice, so
   it cannot also be its one thing that must stand out. A staff tag changes
   FAMILY, which is legible across a street in a way that a second shade of red
   is not.

   IT MOVED ONTO THE SQUARE when the name plate came off. The family change used
   to be carried by the plate going to a lit ground behind a white outline, with
   the lettering following it; with no plate, colour on type would have been all
   that was left, and three white words at distance are three red words that
   happen to be pale. The square is the one box still drawn and the heaviest mark
   on the tag, so it is what goes white-hot -- an outlined white box over a head
   reads as "staff" from further away than any lettering does, and the names
   change with it exactly as they did before.
   ========================================================================== */
.id.staff {
  --aug-border-bg: var(--op-alarm);
  --aug-border-all: 2.4px;
  color: var(--op-alarm);
}

.plate.staff .name {
  color: var(--op-alarm);
}

/* The whole column changes family with the square, or a white marker would sit
   beside two runs still wearing the other palette. */
.plate.staff .user,
.plate.staff .cid {
  color: var(--op-alarm);
  opacity: 0.72;
}

/* The word itself, after the name and quieter than it: what is being said is
   that this person is staff, and the name is still the part being read. */
.badge {
  font: 700 var(--op-fs-micro) / 1 var(--op-font-mono);
  letter-spacing: var(--op-track-micro);
  text-transform: uppercase;
  color: var(--op-alarm);
  opacity: 0.85;
}
</style>
