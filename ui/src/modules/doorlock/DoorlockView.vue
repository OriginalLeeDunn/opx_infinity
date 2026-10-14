<script setup lang="ts">
import { computed, onUnmounted, reactive, ref } from 'vue'
import { emit } from '@/bridge/channel'
import { guard } from '@/bridge/diag'
import { acquireFocus } from '@/bridge/focus'
import { bool, num, own, records, text } from '@/bridge/types'
import type { Payload } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'
import DoorList from './DoorList.vue'
import DoorSettings from './DoorSettings.vue'
import {
  INTENTS,
  copySettings,
  emptyDraft,
  hasLeaves,
  prefill,
  prune,
  readAccess,
  readDefaults,
  readDetail,
  readLeaves,
  readRows,
  readStrings,
  returnsToList,
  toPayload,
  type Access,
  type Defaults,
  type Draft,
  type Intent,
  type Row,
  type Settings,
  type Tab
} from './model'

/**
 * THE DOOR PANEL -- ox_doorlock's web UI (`web/src/App.tsx`, `layouts/doors`,
 * `layouts/settings`) on the OPX design system.
 *
 * ox's page is two routes in one 700x500 box: `/`, the table of every door with a search
 * box, pages of eight and a menu per row; and `/settings/*`, the form with ox's vertical
 * tabs and its Confirm bar. This view is the same two screens in the same box, drawn the
 * way the menu -- the reference surface the owner approved -- draws: a bay with two cut
 * corners and a lit arete, framed rows, red on a dark plate, no Mantine.
 *
 * Lua (`modules/doorlock/client/panel.lua`) owns everything that is a FACT: the rows, a
 * door's detail, what this staff member may do, whether a save landed. This page owns
 * only what is not: the search text, the page of the table, the tab, the draft being
 * typed and the copied settings. Every payload carries Lua's handle and one for another
 * handle is dropped, the rule every view on this surface keeps.
 */

type Handle = string | number

const { t } = useLocale()

const handle = ref<Handle | null>(null)
const open = ref(false)
const visible = ref(true)
const view = ref<'list' | 'settings'>('list')
/** One per open, and the list's key: the list is kept alive while the player is in a
    door's settings (see the template), and a NEW panel starts a new list. */
const session = ref(0)
const tab = ref<Tab>('general')
const mode = ref('')

const access = ref<Access>(readAccess({}))
const defaults = ref<Defaults>(readDefaults({}))
const sounds = ref<string[]>([])
const difficulties = ref<string[]>([])

const rows = ref<Row[]>([])
/** Rows still arriving in parts, swapped in when the last one lands. */
let incoming: Row[] = []
const loaded = ref(false)

const draft = reactive<Draft>(emptyDraft(readDefaults({})))
/** The door whose detail was asked for, while it has not arrived. */
const waitingFor = ref<number | null>(null)
const saving = ref(false)
/** ox's Confirm on a door with no leaf yet: pick it, then save. */
const submitAfterPick = ref(false)
/** ox's clipboard store: "Copy settings" on a row, "Apply copied settings" in the form. */
const clipboard = ref<Settings | null>(null)
/** A row's "Copy settings" waiting on that door's detail, which the table does not hold. */
const copyOnArrival = ref(false)
const confirm = ref<{ id: number; name: string } | null>(null)
/** The last thing the server said about a write, drawn under the form. */
const notice = ref<{ ok: boolean; text: string } | null>(null)

const title = computed(() =>
  view.value === 'list'
    ? t('doorlock.ui.title')
    : draft.id === null
      ? t('doorlock.ui.newDoor')
      : t('doorlock.ui.editDoor', { id: draft.id })
)

function isHandle(value: unknown): value is Handle {
  return typeof value === 'string' || typeof value === 'number'
}

function mine(payload: Payload): boolean {
  return handle.value !== null && payload.handle === handle.value
}

function send(verb: Intent, payload: Payload = {}): void {
  emit(INTENTS[verb], { ...payload, handle: handle.value })
}

/* Focus is held while the panel is open AND shown: the pick step hides it and hands the
   controls back so the staff member can aim. */
let release: (() => void) | undefined

function holdFocus(on: boolean): void {
  if (on && release === undefined) {
    release = acquireFocus({
      id: 'doorlock',
      // An intent: Lua closes the panel and answers with `close`.
      onEscape: () => {
        if (confirm.value !== null) {
          confirm.value = null
          return
        }
        send('dismiss')
      }
    })
  } else if (!on && release !== undefined) {
    release()
    release = undefined
  }
}

function setDraft(next: Draft): void {
  Object.assign(draft, next)
}

function startCreate(next?: Draft): void {
  setDraft(next ?? emptyDraft(defaults.value))
  waitingFor.value = null
  notice.value = null
  tab.value = 'general'
  view.value = 'settings'
}

function startEdit(id: number): void {
  copyOnArrival.value = false
  setDraft(emptyDraft(defaults.value))
  draft.id = id
  waitingFor.value = id
  notice.value = null
  tab.value = 'general'
  view.value = 'settings'
  send('detail', { id })
}

function backToList(): void {
  view.value = 'list'
  waitingFor.value = null
  submitAfterPick.value = false
  send('list')
}

function blank(): void {
  open.value = false
  visible.value = true
  rows.value = []
  incoming = []
  loaded.value = false
  confirm.value = null
  notice.value = null
  saving.value = false
  waitingFor.value = null
  submitAfterPick.value = false
}

useBridge('opx:doorlock:open', (payload: Payload) => {
  guard('doorlock:open', () => {
    if (!isHandle(payload.handle)) return
    cancelWipe()
    blank()
    session.value += 1
    handle.value = payload.handle
    access.value = readAccess(payload.access)
    defaults.value = readDefaults(payload.defaults)
    sounds.value = readStrings(payload.sounds)
    difficulties.value = readStrings(payload.difficulties)
    mode.value = text(payload.mode)
    open.value = true
    const wanted = text(payload.view, 'list')
    const edit = num(payload.edit, -1)
    if (wanted === 'edit' && edit > 0) startEdit(edit)
    else if (wanted === 'create') startCreate(prefill(defaults.value, payload.draft))
    else view.value = 'list'
    holdFocus(true)
  }, undefined)
})

useBridge('opx:doorlock:rows', (payload: Payload) => {
  guard('doorlock:rows', () => {
    if (!mine(payload)) return
    if (num(payload.offset) === 0) incoming = []
    incoming = incoming.concat(readRows(payload.rows))
    if (payload.done === true) {
      rows.value = incoming
      incoming = []
      loaded.value = true
    }
  }, undefined)
})

useBridge('opx:doorlock:detail', (payload: Payload) => {
  guard('doorlock:detail', () => {
    if (!mine(payload)) return
    const door = readDetail(defaults.value, payload.door)
    // A detail for a door this form is no longer on is a late answer, and dropped.
    if (waitingFor.value === null || door.id !== waitingFor.value) return
    waitingFor.value = null
    if (copyOnArrival.value) {
      copyOnArrival.value = false
      clipboard.value = copySettings(door)
      notice.value = { ok: true, text: t('doorlock.ui.copied') }
      view.value = 'list'
      return
    }
    setDraft(door)
  }, undefined)
})

useBridge('opx:doorlock:patch', (payload: Payload) => {
  guard('doorlock:patch', () => {
    if (!mine(payload)) return
    const id = num(payload.id, -1)
    const state = num(payload.state, 1) === 0 ? 0 : 1
    for (const row of rows.value) if (row.id === id) row.state = state
  }, undefined)
})

useBridge('opx:doorlock:picked', (payload: Payload) => {
  guard('doorlock:picked', () => {
    if (!mine(payload)) return
    if (payload.cancelled === true) {
      submitAfterPick.value = false
      return
    }
    const doors = readLeaves(payload.doors)
    if (doors.length === 0) return
    draft.doors = doors
    draft.double = doors.length === 2
    const centre = records([payload.coords])[0]
    const x = num(centre.x, NaN)
    const y = num(centre.y, NaN)
    const z = num(centre.z, NaN)
    draft.coords = Number.isFinite(x) && Number.isFinite(y) && Number.isFinite(z) ? { x, y, z } : null
    if (submitAfterPick.value) {
      submitAfterPick.value = false
      submit()
    }
  }, undefined)
})

/** What a write that landed is called, by verb. */
const DONE: Record<string, string> = {
  save: 'doorlock.staff.saved',
  remove: 'doorlock.staff.removed',
  key: 'doorlock.staff.key_given'
}

/** The door a write was about, by name. A save names the DRAFT -- that is the door
    being written, and its new name is the one to say. Anything else is answered for
    the id Lua echoes back, and the draft is only the last door OPENED: a delete from
    the list was told as "Front Gate deleted." for the Back Room the player removed. */
function doorNamed(verb: string, id: number): string {
  if (verb !== 'save' && id > 0) {
    const row = rows.value.find((entry) => entry.id === id)
    if (row) return row.name || `#${id}`
    return `#${id}`
  }
  return draft.name || `#${draft.id ?? ''}`
}

/** The server's word on a write, in the player's language. */
function describe(verb: string, ok: boolean, code: string, detail: string, id = 0): string {
  if (ok) return t(own(DONE, verb) ?? 'doorlock.answer.done', { door: doorNamed(verb, id) })
  const key = `doorlock.error.${code}`
  const said = t(key, { detail, door: draft.name })
  return said === key ? t('doorlock.error.invalid') : said
}


useBridge('opx:doorlock:result', (payload: Payload) => {
  guard('doorlock:result', () => {
    if (!mine(payload)) return
    const verb = text(payload.verb)
    const ok = bool(payload.ok)
    if (verb === 'save') saving.value = false
    if (verb === 'detail' && !ok) {
      waitingFor.value = null
      view.value = 'list'
    }
    notice.value = { ok, text: describe(verb, ok, text(payload.code), text(payload.detail), num(payload.id)) }
    if (ok && returnsToList(verb) && view.value === 'settings') view.value = 'list'
  }, undefined)
})

useBridge('opx:doorlock:visible', (payload: Payload) => {
  guard('doorlock:visible', () => {
    if (!mine(payload)) return
    visible.value = payload.visible !== false
    holdFocus(open.value && visible.value)
  }, undefined)
})

/* A CLOSED PANEL KEEPS ITS TABLE UNTIL THE FADE HAS RUN. Blanked in the same tick,
   the list lost its rows and its `loaded` flag, and the panel faded out reading
   "Loading..." over an empty table. The confirm goes at once -- it is a question,
   and nobody can answer it any more -- and the rest follows when nothing can see it. */
const WIPE_MS = 240
let wipe: ReturnType<typeof setTimeout> | undefined

function cancelWipe(): void {
  if (wipe !== undefined) clearTimeout(wipe)
  wipe = undefined
}

useBridge('opx:doorlock:close', (payload: Payload) => {
  guard('doorlock:close', () => {
    if (payload.handle !== undefined && !mine(payload)) return
    handle.value = null
    open.value = false
    confirm.value = null
    holdFocus(false)
    cancelWipe()
    wipe = setTimeout(() => {
      wipe = undefined
      if (!open.value) blank()
    }, WIPE_MS)
  }, undefined)
})

onUnmounted(() => {
  cancelWipe()
  holdFocus(false)
})

// ── the intents ────────────────────────────────────────────────────────────

function submit(): void {
  if (!access.value.save || saving.value) return
  // ox's Confirm on a new door is where the targeting starts.
  if (!hasLeaves(draft)) {
    submitAfterPick.value = true
    pick()
    return
  }
  saving.value = true
  notice.value = null
  send('save', {
    id: draft.id ?? undefined,
    door: prune(toPayload(draft, defaults.value)) as Payload
  })
}

function pick(): void {
  send('pick', { double: draft.double, id: draft.id ?? undefined })
}

function copyRow(row: Row): void {
  // ox copies from the row it already holds; a row here is a summary with no rules in
  // it, so the door's detail is asked for and copied the moment it lands -- the table
  // stays where it was, as ox's does.
  copyOnArrival.value = true
  waitingFor.value = row.id
  send('detail', { id: row.id })
}

function applyCopy(): void {
  if (clipboard.value === null) return
  const copy = clipboard.value
  Object.assign(draft, {
    ...copy,
    characters: [...copy.characters],
    groups: copy.groups.map((row) => ({ ...row })),
    items: copy.items.map((row) => ({ ...row })),
    steps: copy.steps.map((step) => (typeof step === 'string' ? step : { ...step }))
  })
  notice.value = { ok: true, text: t('doorlock.ui.applied') }
}

function copyCurrent(): void {
  clipboard.value = copySettings(draft)
  notice.value = { ok: true, text: t('doorlock.ui.copied') }
}

function askDelete(id: number, name: string): void {
  if (!access.value.remove) return
  confirm.value = { id, name }
}

function confirmDelete(): void {
  if (confirm.value === null) return
  send('delete', { id: confirm.value.id })
  confirm.value = null
}

function toggleRow(row: Row): void {
  if (!access.value.lock) return
  send('state', { id: row.id, state: row.state === 1 ? 0 : 1 })
}

function teleport(row: Row): void {
  if (!access.value.teleport) return
  send('teleport', { id: row.id })
}

function giveKey(): void {
  if (!access.value.key || draft.id === null) return
  send('key', { id: draft.id })
}
</script>

<template>
  <div class="panel op-plane op-ink" :class="{ open: open && visible }">
    <div class="bay op-bay op-arete" data-augmented-ui="tr-clip bl-clip border">
      <div class="bay-inner op-interlace">
        <header class="head">
          <span class="op-eyebrow head-kicker">OPX // 77</span>
          <h1 class="head-title op-label op-truncate">{{ title }}</h1>
          <span v-if="mode" class="head-mode op-value">{{ t('doorlock.ui.mode', { mode }) }}</span>
          <button
            class="close op-frame"
            data-augmented-ui="tr-clip border"
            :title="t('doorlock.ui.close')"
            @click="send('dismiss')"
          >
            ×
          </button>
        </header>

        <!-- KEPT MOUNTED ACROSS A DOOR'S SETTINGS, hidden rather than unmounted. The search,
             the page and the sort are the list's own, and an Edit and a Back used to
             cost all three: the staff member who found a door on page 3 of a search
             came back to page 1 of everything. A new open is a new key, so the next
             panel starts clean. -->
        <DoorList
          v-show="view === 'list'"
          :key="session"
          :rows="rows"
          :loaded="loaded"
          :access="access"
          @create="startCreate()"
          @edit="startEdit"
          @copy="copyRow"
          @teleport="teleport"
          @toggle="toggleRow"
          @delete="(row: Row) => askDelete(row.id, row.name)"
        />

        <DoorSettings
          v-if="view !== 'list'"
          v-model:tab="tab"
          :draft="draft"
          :defaults="defaults"
          :access="access"
          :sounds="sounds"
          :difficulties="difficulties"
          :loading="waitingFor !== null"
          :saving="saving"
          :has-copy="clipboard !== null"
          :notice="notice"
          @back="backToList"
          @submit="submit"
          @pick="pick"
          @apply="applyCopy"
          @copy="copyCurrent"
          @key="giveKey"
          @delete="draft.id !== null && askDelete(draft.id, draft.name)"
        />

        <p v-if="view === 'list' && notice" class="notice op-copy" :class="{ bad: !notice.ok }">{{ notice.text }}</p>
      </div>
    </div>

    <!-- ox's openConfirmModal: one question, two answers, the red one on the right. -->
    <div v-if="confirm" class="veil" @click.self="confirm = null">
      <div class="ask op-bay op-arete" data-augmented-ui="tr-clip bl-clip border">
        <div class="ask-inner op-interlace">
          <p class="op-eyebrow">{{ t('doorlock.ui.confirmTitle') }}</p>
          <p class="op-copy ask-text">{{ t('doorlock.ui.confirmDelete', { door: confirm.name }) }}</p>
          <div class="ask-row">
            <button class="btn op-frame" data-augmented-ui="tr-clip border" @click="confirm = null">
              <span class="op-label">{{ t('doorlock.ui.cancel') }}</span>
            </button>
            <button class="btn danger op-frame is-on" data-augmented-ui="tr-clip border" @click="confirmDelete">
              <span class="op-label">{{ t('doorlock.ui.confirm') }}</span>
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
/* =============================================================================
   THE PANEL -- a centred bay, the menu's anchor-center case: no tilt (a centred plane
   rotated about its middle is paper on a spindle), same cut, same arete, same plate.
   ox's box is 700x500; this one is a little larger because every label here is a
   locale string and French runs a third longer.
   ========================================================================== */
.panel {
  position: absolute;
  left: 50%;
  top: 50%;
  transform: translate(-50%, -50%);
  display: flex;
  width: min(820px, calc(100vw - var(--op-inset-x) * 2));
  height: min(600px, calc(100vh - var(--op-inset-y) * 2));
  opacity: 0;
  pointer-events: none;
  transition: opacity var(--op-dur-fast) linear;
  --op-pop: 10px;
  --op-origin: center center;
}

.panel.open {
  opacity: 1;
  pointer-events: auto;
}

.bay {
  position: relative;
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  /* A panel over a street is a plate, unlike the menu's strip: the table and the form
     are dense enough that type straight on the world would not read. */
  background: var(--op-plate-quiet);
}

.bay-inner {
  position: relative;
  z-index: 1;
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
  padding: var(--op-space-3) var(--op-space-4) var(--op-space-4);
  color: var(--op-red-text);
}

.head {
  display: flex;
  align-items: baseline;
  gap: var(--op-space-3);
  padding: 0 var(--op-space-6) var(--op-space-3) var(--op-space-1);
  border-bottom: 1px solid var(--op-red-idle);
  margin-bottom: var(--op-space-3);
}

.head-kicker {
  color: var(--op-red-deep);
}

.head-title {
  flex: 1;
  margin: 0;
  font-size: var(--op-fs-title);
  color: var(--op-red);
}

.head-mode {
  color: var(--op-text-dim);
}

.close {
  position: absolute;
  top: var(--op-space-3);
  right: var(--op-space-4);
  width: 28px;
  height: 24px;
  border: 0;
  cursor: pointer;
  font: 700 16px / 1 var(--op-font-mono);
}

.notice {
  margin: var(--op-space-2) 0 0;
  color: var(--op-text-dim);
}

.notice.bad {
  color: var(--op-alarm);
}

.veil {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  background: rgba(var(--op-plate-rgb), 0.55);
  z-index: 5;
}

.ask {
  width: 360px;
  background: var(--op-plate);
}

.ask-inner {
  padding: var(--op-space-4);
  display: flex;
  flex-direction: column;
  gap: var(--op-space-3);
}

.ask-text {
  margin: 0;
  color: var(--op-text);
  overflow-wrap: anywhere;
}

.ask-row {
  display: flex;
  justify-content: flex-end;
  gap: var(--op-space-2);
}

.btn {
  border: 0;
  padding: var(--op-space-2) var(--op-space-4);
  cursor: pointer;
}

.btn.danger {
  --aug-border-bg: var(--op-alarm);
  color: var(--op-alarm);
}
</style>
