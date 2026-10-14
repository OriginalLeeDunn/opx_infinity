<script setup lang="ts">
import { computed } from 'vue'
import { own } from '@/bridge/types'
import { useLocale } from '@/composables/useLocale'
import { GLYPHS } from '@/modules/target/glyphs'
import { TABS, hasLeaves, stepKey, type Access, type Defaults, type Draft, type Step, type Tab } from './model'

/**
 * ox's `layouts/settings`: vertical tabs down the left (back to Doors, General,
 * Characters, Groups, Items, Lockpick -- disabled until the door is pickable -- and
 * Sound), the tab's fields, and the Submit bar under them (Confirm door, apply copied
 * settings, delete).
 *
 * THE FIELDS ARE OX'S, ONE FOR ONE. General: door name, passcode, autolock interval,
 * interact distance and the switches -- locked, double, automatic, lockpick, hide UI,
 * hold open -- plus this server's "on duty only". ox's door rate is not here: Open77's
 * door natives have no speed to set (docs/MANUAL.md, "Door locks"). Characters, Groups (group +
 * grade), Items (item, metadata type, remove on use) and Lockpick (one difficulty per
 * row, a custom row taking ox's area size and speed multiplier) are ox's row editors,
 * each with ox's "create a new row" button; ox puts an item's metadata and an
 * difficulty's custom fields in a small modal, and here they sit on the row itself.
 * Sound is ox's two selects, from the list `config/doorlock.lua` names.
 *
 * And the one General block ox does not have on its form, because ox asks for it after
 * Confirm: the door itself. "Pick in world" hands the controls back, the staff member
 * aims at the door (twice for a double door) and the panel comes back with it. Confirm
 * on a door with no leaf yet starts the same step and saves when it ends -- ox's order.
 *
 * The draft is the parent's reactive object, edited in place: it is the page's own
 * state, never a fact, and nothing in it reaches the server until Confirm.
 */

const props = defineProps<{
  draft: Draft
  defaults: Defaults
  access: Access
  sounds: string[]
  difficulties: string[]
  loading: boolean
  saving: boolean
  hasCopy: boolean
  notice: { ok: boolean; text: string } | null
}>()
const tab = defineModel<Tab>('tab', { required: true })
const emit = defineEmits<{
  back: []
  submit: []
  pick: []
  apply: []
  copy: []
  key: []
  delete: []
}>()

const { t } = useLocale()

const ICONS: Record<Tab, string> = {
  general: 'gear',
  characters: 'person',
  groups: 'shield',
  items: 'box',
  lockpick: 'tool',
  sound: 'bolt'
}

function paths(name: string): string[] {
  return own(GLYPHS, name) ?? []
}

const editable = computed(() => props.access.save && !props.loading)

type Flag = 'state' | 'double' | 'auto' | 'lockpick' | 'hideUi' | 'holdOpen' | 'onDuty'
const SWITCHES: Flag[] = ['state', 'double', 'auto', 'lockpick', 'hideUi', 'holdOpen', 'onDuty']

function flip(flag: Flag): void {
  if (!editable.value) return
  props.draft[flag] = !props.draft[flag]
  // A door that stopped being double keeps its first leaf; one that became double
  // waits for its second, which the Doors block asks for.
  if (flag === 'double' && !props.draft.double && props.draft.doors.length > 1) {
    props.draft.doors = props.draft.doors.slice(0, 1)
  }
  if (flag === 'lockpick' && !props.draft.lockpick && tab.value === 'lockpick') tab.value = 'general'
}

function numberOf(event: Event, low: number, high: number, decimals = 0): number {
  const value = Number((event.target as HTMLInputElement).value)
  if (!Number.isFinite(value)) return low
  const bounded = Math.min(high, Math.max(low, value))
  const scale = 10 ** decimals
  return Math.round(bounded * scale) / scale
}

// ── the row editors ────────────────────────────────────────────────────────

function addCharacter(): void {
  if (props.draft.characters.length < props.defaults.charactersMax) props.draft.characters.push('')
}

function addGroup(): void {
  if (props.draft.groups.length < props.defaults.groupsMax) props.draft.groups.push({ name: '', grade: 0 })
}

function addItem(): void {
  if (props.draft.items.length < props.defaults.itemsMax) {
    props.draft.items.push({ name: '', metadata: '', remove: false })
  }
}

function addStep(): void {
  if (props.draft.steps.length < props.defaults.stepsMax) {
    props.draft.steps.push(props.difficulties[0] ?? 'medium')
  }
}

/** The select's value for a step: its name, or 'custom'. */
function stepChoice(step: Step): string {
  return typeof step === 'string' ? step : '__custom'
}

function chooseStep(index: number, event: Event): void {
  const value = (event.target as HTMLSelectElement).value
  props.draft.steps[index] = value === '__custom' ? { areaSize: 40, speedMultiplier: 1 } : value
}

function setCustom(index: number, field: 'areaSize' | 'speedMultiplier', event: Event): void {
  const step = props.draft.steps[index]
  if (typeof step === 'string') return
  step[field] = field === 'areaSize' ? numberOf(event, 1, 360) : numberOf(event, 0.1, 10, 2)
}

const defaultSteps = computed(() =>
  props.defaults.steps.map((step) => t(stepKey(step))).join(', ')
)

const leavesNeeded = computed(() => (props.draft.double ? 2 : 1))
const ready = computed(() => hasLeaves(props.draft))
</script>

<template>
  <div class="settings">
    <nav class="tabs">
      <button class="tab op-frame" data-augmented-ui="tr-clip border" @click="emit('back')">
        <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('back')" :key="n" :d="d" /></svg>
        <span class="op-label op-truncate">{{ t('doorlock.ui.tab.back') }}</span>
      </button>
      <button
        v-for="name in TABS"
        :key="name"
        class="tab op-frame"
        data-augmented-ui="tr-clip border"
        :class="{ 'is-on': tab === name, 'op-lift': tab === name, 'is-off': name === 'lockpick' && !draft.lockpick }"
        :disabled="name === 'lockpick' && !draft.lockpick"
        :title="name === 'lockpick' && !draft.lockpick ? t('doorlock.ui.lockpickOff') : ''"
        @click="tab = name"
      >
        <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths(ICONS[name])" :key="n" :d="d" /></svg>
        <span class="op-label op-truncate">{{ t(`doorlock.ui.tab.${name}`) }}</span>
      </button>
    </nav>

    <section class="pane">
      <p v-if="loading" class="hint op-copy">{{ t('doorlock.ui.loading') }}</p>

      <!-- ── General ── ox's Inputs + Switches, and the door itself. -->
      <div v-else-if="tab === 'general'" class="fields">
        <div class="grid">
          <label class="field">
            <span class="op-eyebrow">{{ t('doorlock.ui.name') }}</span>
            <input v-model="draft.name" class="input op-copy" type="text" :maxlength="defaults.nameMax"
              :disabled="!editable" />
          </label>
          <label class="field">
            <span class="op-eyebrow">{{ t('doorlock.ui.passcode') }}</span>
            <input v-model="draft.passcode" class="input op-copy" type="text" autocomplete="off"
              :maxlength="defaults.passcodeMax" :disabled="!editable || draft.clearPasscode"
              :placeholder="draft.hasPasscode ? t('doorlock.ui.passcodeKept') : ''" />
            <button v-if="draft.hasPasscode" class="mini" :class="{ on: draft.clearPasscode }" :disabled="!editable"
              @click.prevent="draft.clearPasscode = !draft.clearPasscode">
              <span class="box" :class="{ ticked: draft.clearPasscode }"><svg viewBox="0 0 13 13" aria-hidden="true"><path d="M2.6 6.8 5 9.2 10 3.6" /></svg></span>
              <span class="op-eyebrow">{{ t('doorlock.ui.passcodeClear') }}</span>
            </button>
          </label>
          <label class="field" :title="t('doorlock.ui.autolockHint')">
            <span class="op-eyebrow">{{ t('doorlock.ui.autolock') }}</span>
            <input class="input op-value" type="number" min="0" :max="defaults.autolockMax" step="1"
              :value="draft.autolock" :disabled="!editable"
              @change="draft.autolock = numberOf($event, 0, defaults.autolockMax)" />
          </label>
          <label class="field" :title="t('doorlock.ui.maxDistanceHint')">
            <span class="op-eyebrow">{{ t('doorlock.ui.maxDistance') }}</span>
            <input class="input op-value" type="number" min="0.5" :max="defaults.maxReach" step="0.1"
              :value="draft.maxDistance" :disabled="!editable"
              @change="draft.maxDistance = numberOf($event, 0.5, defaults.maxReach, 1)" />
          </label>
        </div>

        <div class="switches">
          <button v-for="flag in SWITCHES" :key="flag" class="switch" :class="{ on: draft[flag] }"
            :disabled="!editable" :title="t(`doorlock.ui.${flag}Hint`)" @click="flip(flag)">
            <span class="box" :class="{ ticked: draft[flag] }">
              <svg viewBox="0 0 13 13" aria-hidden="true"><path d="M2.6 6.8 5 9.2 10 3.6" /></svg>
            </span>
            <span class="op-label op-truncate">{{ t(`doorlock.ui.${flag}`) }}</span>
          </button>
        </div>

        <div class="doors">
          <span class="op-eyebrow">{{ t('doorlock.ui.doors') }}</span>
          <ul class="leaves">
            <li v-for="(leaf, at) in draft.doors" :key="leaf.native" class="op-value">
              {{ at + 1 }} · {{ leaf.native }}
            </li>
            <li v-if="draft.doors.length === 0" class="op-copy dim">{{ t('doorlock.ui.noLeaf') }}</li>
            <li v-else-if="draft.doors.length < leavesNeeded" class="op-copy warn">{{ t('doorlock.ui.leafMissing') }}</li>
          </ul>
          <button class="btn op-frame" data-augmented-ui="tr-clip border" :class="{ 'is-off': !editable }"
            :disabled="!editable" :title="t('doorlock.ui.pickHint')" @click="emit('pick')">
            <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('door')" :key="n" :d="d" /></svg>
            <span class="op-label">{{ t('doorlock.ui.pickWorld') }}</span>
          </button>
        </div>
      </div>

      <!-- ── Characters ── -->
      <div v-else-if="tab === 'characters'" class="rows">
        <div v-for="(_, at) in draft.characters" :key="`c${at}`" class="line">
          <input v-model="draft.characters[at]" class="input op-copy" type="text" maxlength="32"
            :placeholder="t('doorlock.ui.character')" :disabled="!editable" />
          <button class="icon danger" :title="t('doorlock.ui.deleteRow')" :disabled="!editable"
            @click="draft.characters.splice(at, 1)">
            <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('trash')" :key="n" :d="d" /></svg>
          </button>
        </div>
        <button class="add op-frame" data-augmented-ui="tr-clip border" :disabled="!editable"
          :title="t('doorlock.ui.addRow')" @click="addCharacter">+</button>
      </div>

      <!-- ── Groups ── ox's map of group to minimum grade, as rows. -->
      <div v-else-if="tab === 'groups'" class="rows">
        <div v-for="(row, at) in draft.groups" :key="`g${at}`" class="line">
          <input v-model="row.name" class="input op-copy" type="text" maxlength="48"
            :placeholder="t('doorlock.ui.group')" :disabled="!editable" />
          <input class="input op-value narrow" type="number" min="0" max="1000" step="1" :value="row.grade"
            :placeholder="t('doorlock.ui.grade')" :disabled="!editable"
            @change="row.grade = numberOf($event, 0, 1000)" />
          <button class="icon danger" :title="t('doorlock.ui.deleteRow')" :disabled="!editable"
            @click="draft.groups.splice(at, 1)">
            <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('trash')" :key="n" :d="d" /></svg>
          </button>
        </div>
        <button class="add op-frame" data-augmented-ui="tr-clip border" :disabled="!editable"
          :title="t('doorlock.ui.addRow')" @click="addGroup">+</button>
      </div>

      <!-- ── Items ── name, ox's "metadata type", and "remove on use". -->
      <div v-else-if="tab === 'items'" class="rows">
        <div v-for="(row, at) in draft.items" :key="`i${at}`" class="line">
          <input v-model="row.name" class="input op-copy" type="text" maxlength="48"
            :placeholder="t('doorlock.ui.item')" :disabled="!editable" />
          <input v-model="row.metadata" class="input op-copy" type="text" maxlength="48"
            :placeholder="t('doorlock.ui.metadata')" :disabled="!editable" />
          <button class="mini" :class="{ on: row.remove }" :disabled="!editable" @click="row.remove = !row.remove">
            <span class="box" :class="{ ticked: row.remove }"><svg viewBox="0 0 13 13" aria-hidden="true"><path d="M2.6 6.8 5 9.2 10 3.6" /></svg></span>
            <span class="op-eyebrow">{{ t('doorlock.ui.remove') }}</span>
          </button>
          <button class="icon danger" :title="t('doorlock.ui.deleteRow')" :disabled="!editable"
            @click="draft.items.splice(at, 1)">
            <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('trash')" :key="n" :d="d" /></svg>
          </button>
        </div>
        <button class="add op-frame" data-augmented-ui="tr-clip border" :disabled="!editable"
          :title="t('doorlock.ui.addRow')" @click="addItem">+</button>
      </div>

      <!-- ── Lockpick ── ox's skill-check sequence, one row per check. -->
      <div v-else-if="tab === 'lockpick'" class="rows">
        <p v-if="draft.steps.length === 0" class="hint op-copy">
          {{ t('doorlock.ui.stepsDefault', { steps: defaultSteps }) }}
        </p>
        <div v-for="(step, at) in draft.steps" :key="`s${at}`" class="line">
          <select class="input op-copy" :value="stepChoice(step)" :disabled="!editable" @change="chooseStep(at, $event)">
            <option v-for="name in difficulties" :key="name" :value="name">{{ t(`doorlock.difficulty.${name}`) }}</option>
            <option value="__custom">{{ t('doorlock.ui.custom') }}</option>
          </select>
          <template v-if="typeof step !== 'string'">
            <input class="input op-value narrow" type="number" min="1" max="360" :value="step.areaSize"
              :title="t('doorlock.ui.areaHint')" :placeholder="t('doorlock.ui.areaSize')" :disabled="!editable"
              @change="setCustom(at, 'areaSize', $event)" />
            <input class="input op-value narrow" type="number" min="0.1" max="10" step="0.05"
              :value="step.speedMultiplier" :title="t('doorlock.ui.speedHint')" :placeholder="t('doorlock.ui.speed')"
              :disabled="!editable" @change="setCustom(at, 'speedMultiplier', $event)" />
          </template>
          <button class="icon danger" :title="t('doorlock.ui.deleteRow')" :disabled="!editable"
            @click="draft.steps.splice(at, 1)">
            <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('trash')" :key="n" :d="d" /></svg>
          </button>
        </div>
        <button class="add op-frame" data-augmented-ui="tr-clip border" :disabled="!editable"
          :title="t('doorlock.ui.addRow')" @click="addStep">+</button>
      </div>

      <!-- ── Sound ── -->
      <div v-else class="fields">
        <p v-if="sounds.length === 0" class="hint op-copy">{{ t('doorlock.ui.noSounds') }}</p>
        <label class="field">
          <span class="op-eyebrow">{{ t('doorlock.ui.lockSound') }}</span>
          <select v-model="draft.lockSound" class="input op-copy" :disabled="!editable">
            <option value="">{{ t('doorlock.ui.soundNone') }}</option>
            <option v-for="name in sounds" :key="name" :value="name">{{ name }}</option>
            <option v-if="draft.lockSound && !sounds.includes(draft.lockSound)" :value="draft.lockSound">
              {{ draft.lockSound }}
            </option>
          </select>
        </label>
        <label class="field">
          <span class="op-eyebrow">{{ t('doorlock.ui.unlockSound') }}</span>
          <select v-model="draft.unlockSound" class="input op-copy" :disabled="!editable">
            <option value="">{{ t('doorlock.ui.soundNone') }}</option>
            <option v-for="name in sounds" :key="name" :value="name">{{ name }}</option>
            <option v-if="draft.unlockSound && !sounds.includes(draft.unlockSound)" :value="draft.unlockSound">
              {{ draft.unlockSound }}
            </option>
          </select>
        </label>
      </div>

      <!-- ── ox's Submit bar ── -->
      <footer class="submit">
        <p v-if="notice" class="notice op-copy" :class="{ bad: !notice.ok }">{{ notice.text }}</p>
        <p v-else-if="!ready" class="notice op-copy">{{ t('doorlock.ui.needDoor') }}</p>
        <div class="actions">
          <button class="btn wide op-frame" data-augmented-ui="tr-clip border"
            :class="{ 'is-on': editable && !saving, 'is-off': !editable || saving }"
            :disabled="!editable || saving" :title="access.save ? '' : t('doorlock.ui.denied')" @click="emit('submit')">
            <span class="op-label">{{ saving ? t('doorlock.ui.saving') : t('doorlock.ui.submit') }}</span>
          </button>
          <button class="icon" :title="t('doorlock.ui.action.copy')" :disabled="loading" @click="emit('copy')">
            <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('folder')" :key="n" :d="d" /></svg>
          </button>
          <button class="icon" :class="{ off: !hasCopy || !editable }" :disabled="!hasCopy || !editable"
            :title="hasCopy ? t('doorlock.ui.applyCopy') : t('doorlock.ui.noCopy')" @click="emit('apply')">
            <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('import')" :key="n" :d="d" /></svg>
          </button>
          <button v-if="draft.id !== null" class="icon" :class="{ off: !access.key }" :disabled="!access.key"
            :title="access.key ? t('doorlock.ui.action.key') : t('doorlock.ui.denied')" @click="emit('key')">
            <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('key')" :key="n" :d="d" /></svg>
          </button>
          <button v-if="draft.id !== null" class="icon danger" :class="{ off: !access.remove }"
            :disabled="!access.remove" :title="access.remove ? t('doorlock.ui.action.delete') : t('doorlock.ui.denied')"
            @click="emit('delete')">
            <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('trash')" :key="n" :d="d" /></svg>
          </button>
        </div>
      </footer>
    </section>
  </div>
</template>

<style scoped>
.settings {
  display: flex;
  flex: 1;
  min-height: 0;
  gap: var(--op-space-4);
}

svg {
  flex: none;
  width: 16px;
  height: 16px;
  fill: none;
  stroke: currentcolor;
  stroke-width: 1.9;
  stroke-linecap: round;
  stroke-linejoin: round;
}

/* ox's vertical Tabs.List: framed rows, the chosen one lit and stepped out. */
.tabs {
  flex: none;
  width: 168px;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
}

.tab {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  padding: var(--op-space-2) var(--op-space-3);
  border: 0;
  cursor: pointer;
  text-align: left;
  transition: transform 80ms var(--op-ease);
}

.tab .op-label {
  font-size: var(--op-fs-body);
}

.tab.is-on {
  transform: translateX(var(--op-pop, 10px));
}

.pane {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.fields,
.rows {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-3);
  padding-right: var(--op-space-1);
  /* Scrolled by the wheel, like every list on the surface: no OS scrollbar. */
  scrollbar-width: none;
}

.fields::-webkit-scrollbar,
.rows::-webkit-scrollbar {
  width: 0;
  height: 0;
}

.rows {
  gap: var(--op-space-2);
}

.grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--op-space-3);
}

.field {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  min-width: 0;
  color: var(--op-red-deep);
}

.input {
  min-width: 0;
  flex: 1;
  height: 30px;
  padding: 0 var(--op-space-2);
  border: 1px solid var(--op-red-idle);
  background: var(--op-plate);
  color: var(--op-text);
  outline: none;
  transition: border-color var(--op-dur-fast) linear;
}

.input:focus {
  border-color: var(--op-red);
}

.input:disabled {
  color: var(--op-text-faint);
  border-color: rgba(174, 211, 224, 0.14);
}

.input.narrow {
  flex: 0 0 96px;
}

select.input option {
  background: rgb(var(--op-plate-rgb));
  color: var(--op-text);
}

.switches {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--op-space-2) var(--op-space-4);
}

.switch,
.mini {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  border: 0;
  background: none;
  color: var(--op-red-text);
  padding: var(--op-space-1) 0;
  cursor: pointer;
  text-align: left;
  min-width: 0;
}

.switch.on,
.mini.on {
  color: var(--op-red);
}

.switch:disabled,
.mini:disabled {
  color: var(--op-text-faint);
  cursor: default;
}

.switch .op-label {
  font-size: var(--op-fs-body);
}

/* The menu's checkbox: a frame, a fill when ticked, and a stroked tick. */
.box {
  flex: none;
  width: 13px;
  height: 13px;
  border: 1px solid currentcolor;
  transition: background var(--op-dur-fast) linear;
}

.box svg {
  width: 100%;
  height: 100%;
  stroke: var(--op-ink-on);
  stroke-width: 2.2;
  stroke-dasharray: 13;
  stroke-dashoffset: 13;
  transition: stroke-dashoffset var(--op-dur) var(--op-ease) var(--op-dur-fast);
}

.box.ticked {
  background: var(--op-red);
}

.box.ticked svg {
  stroke-dashoffset: 0;
}

.doors {
  display: flex;
  flex-direction: column;
  gap: var(--op-space-2);
  padding-top: var(--op-space-2);
  border-top: 1px solid var(--op-red-idle);
  color: var(--op-red-deep);
}

.leaves {
  list-style: none;
  margin: 0;
  padding: 0;
  color: var(--op-text);
}

.dim,
.hint {
  color: var(--op-text-dim);
  margin: 0;
}

.warn {
  color: var(--op-alarm);
}

.line {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
}

.btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: var(--op-space-2);
  align-self: flex-start;
  border: 0;
  padding: var(--op-space-2) var(--op-space-4);
  cursor: pointer;
}

.btn.wide {
  flex: 1;
}

.add {
  align-self: stretch;
  height: 28px;
  border: 0;
  cursor: pointer;
  font: 700 16px / 1 var(--op-font-mono);
}

.icon {
  border: 0;
  background: none;
  color: var(--op-red-text);
  padding: 4px;
  cursor: pointer;
  display: grid;
  place-items: center;
}

.icon:hover:not(.off):not(:disabled) {
  color: var(--op-red);
}

.icon.danger:hover:not(.off):not(:disabled) {
  color: var(--op-alarm);
}

.icon.off,
.icon:disabled {
  color: var(--op-text-faint);
  cursor: default;
}

.submit {
  flex: none;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-2);
  padding-top: var(--op-space-3);
  margin-top: var(--op-space-3);
  border-top: 1px solid var(--op-red-idle);
}

.notice {
  margin: 0;
  color: var(--op-text-dim);
}

.notice.bad {
  color: var(--op-alarm);
}

.actions {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
}
</style>
