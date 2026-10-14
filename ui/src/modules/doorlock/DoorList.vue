<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useLocale } from '@/composables/useLocale'
import { own } from '@/bridge/types'
import { GLYPHS } from '@/modules/target/glyphs'
import { PAGE_SIZE, type Access, type Row } from './model'

/**
 * ox's `layouts/doors`: the Header (a + that starts a new door, the search box, the
 * close button -- the close is the panel's own here) and the DoorTable (ID, name and
 * ox's zone column, sortable, pages of eight, a menu per row: Settings, Copy settings,
 * Teleport to door, Delete door).
 *
 * The zone column is the one thing that does not come over: ox reads it off GTA's map
 * (`GetNameOfZone`), and Night City exposes no district name to a script. The state and
 * the distance from the player take its place, which is what the owner asked the table
 * to show. Each row's actions are drawn inline rather than behind a dots menu: a menu
 * that opens on a click is two clicks for every action, and the panel is wide enough.
 *
 * The filter and the page are the only things this component decides, and both are over
 * rows Lua already sent.
 */

const props = defineProps<{ rows: Row[]; loaded: boolean; access: Access }>()
const emit = defineEmits<{
  create: []
  edit: [id: number]
  copy: [row: Row]
  teleport: [row: Row]
  toggle: [row: Row]
  delete: [row: Row]
}>()

const { t } = useLocale()

const search = ref('')
const page = ref(1)

/** ox sorts on a header click; id, name, state or distance, either way. */
type Column = 'id' | 'name' | 'state' | 'distance'
const sortBy = ref<Column>('id')
const ascending = ref(true)

function sort(column: Column): void {
  if (sortBy.value === column) ascending.value = !ascending.value
  else {
    sortBy.value = column
    ascending.value = true
  }
}

/** Plain substring, every word: `back room` finds "Back Room B" and "#12 back room". */
const filtered = computed(() => {
  const words = search.value.toLowerCase().split(/\s+/).filter((word) => word !== '')
  const list = words.length === 0
    ? props.rows.slice()
    : props.rows.filter((row) => {
        const haystack = `${row.id} ${row.name}`.toLowerCase()
        return words.every((word) => haystack.includes(word))
      })
  const column = sortBy.value
  const sign = ascending.value ? 1 : -1
  list.sort((a, b) => {
    if (column === 'name') return a.name.localeCompare(b.name) * sign
    // A door elsewhere sorts after every door here, whichever way the column runs.
    if (column === 'distance') {
      if (a.distance < 0 !== b.distance < 0) return a.distance < 0 ? 1 : -1
      return (a.distance - b.distance) * sign
    }
    return (a[column] - b[column]) * sign
  })
  return list
})

const pages = computed(() => Math.max(1, Math.ceil(filtered.value.length / PAGE_SIZE)))
const shown = computed(() => filtered.value.slice((page.value - 1) * PAGE_SIZE, page.value * PAGE_SIZE))

// ox resets to the first page on a new filter; a page past the end after a delete
// falls back to the last one.
watch(search, () => {
  page.value = 1
})
watch(pages, (count) => {
  if (page.value > count) page.value = count
})

function paths(name: string): string[] {
  return own(GLYPHS, name) ?? []
}

function distance(row: Row): string {
  return row.distance < 0 ? t('doorlock.ui.elsewhere') : t('doorlock.ui.metres', { n: row.distance.toFixed(1).replace('.', t('doorlock.ui.decimal')) })
}

/** "1 door", "0 porte": zero and one are keys of their own, because English and French
    part on zero and the page does not know which language it is speaking. */
const countLabel = computed(() => {
  const n = filtered.value.length
  const key = n === 0 ? 'doorlock.ui.countZero' : n === 1 ? 'doorlock.ui.countOne' : 'doorlock.ui.count'
  return t(key, { n })
})

function mark(column: Column): string {
  if (sortBy.value !== column) return ''
  return ascending.value ? '▲' : '▼'
}
</script>

<template>
  <div class="list">
    <div class="bar">
      <button
        class="add op-frame"
        data-augmented-ui="tr-clip border"
        :class="{ 'is-off': !access.save }"
        :title="access.save ? t('doorlock.ui.create') : t('doorlock.ui.denied')"
        :disabled="!access.save"
        @click="emit('create')"
      >
        <svg viewBox="0 0 24 24" aria-hidden="true"><path v-for="(d, at) in paths('plus')" :key="at" :d="d" /></svg>
      </button>
      <label class="search op-frame" data-augmented-ui="tr-clip border">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path v-for="(d, at) in paths('search')" :key="at" :d="d" /></svg>
        <input v-model="search" class="op-copy" type="text" :placeholder="t('doorlock.ui.search')" maxlength="64" />
      </label>
      <span class="count op-value">{{ countLabel }}</span>
    </div>

    <div class="table">
      <div class="thead op-eyebrow">
        <button class="th c-id" @click="sort('id')">{{ t('doorlock.ui.col.id') }} {{ mark('id') }}</button>
        <button class="th c-name" @click="sort('name')">{{ t('doorlock.ui.col.name') }} {{ mark('name') }}</button>
        <button class="th c-state" @click="sort('state')">{{ t('doorlock.ui.col.state') }} {{ mark('state') }}</button>
        <button class="th c-dist" @click="sort('distance')">
          {{ t('doorlock.ui.col.distance') }} {{ mark('distance') }}
        </button>
        <span class="th c-act"></span>
      </div>

      <p v-if="!loaded" class="empty op-copy">{{ t('doorlock.ui.loading') }}</p>
      <p v-else-if="shown.length === 0" class="empty op-copy">{{ t('doorlock.ui.empty') }}</p>

      <ul v-else class="rows">
        <li v-for="(row, at) in shown" :key="row.id" class="op-enter" :style="`--op-slot: ${at}`">
          <div class="row op-frame" data-augmented-ui="tr-clip border" @dblclick="emit('edit', row.id)">
            <span class="c-id op-value">#{{ row.id }}</span>
            <span class="c-name op-label op-truncate">
              {{ row.name }}
              <small v-if="row.double" class="tag op-eyebrow">{{ t('doorlock.ui.doubleTag') }}</small>
              <small v-if="row.seeded" class="tag op-eyebrow">{{ t('doorlock.ui.seeded') }}</small>
            </span>
            <span class="c-state op-value" :class="{ unlocked: row.state === 0 }">
              {{ row.state === 1 ? t('doorlock.ui.locked') : t('doorlock.ui.unlocked') }}
            </span>
            <span class="c-dist op-value">{{ distance(row) }}</span>
            <span class="c-act">
              <button class="icon" :title="t('doorlock.ui.action.edit')" @click="emit('edit', row.id)">
                <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('gear')" :key="n" :d="d" /></svg>
              </button>
              <button class="icon" :title="t('doorlock.ui.action.copy')" @click="emit('copy', row)">
                <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('folder')" :key="n" :d="d" /></svg>
              </button>
              <button
                class="icon"
                :class="{ off: !access.lock }"
                :disabled="!access.lock"
                :title="access.lock ? t(row.state === 1 ? 'doorlock.ui.action.unlock' : 'doorlock.ui.action.lock') : t('doorlock.ui.denied')"
                @click="emit('toggle', row)"
              >
                <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('lock')" :key="n" :d="d" /></svg>
              </button>
              <button
                class="icon"
                :class="{ off: !access.teleport }"
                :disabled="!access.teleport"
                :title="access.teleport ? t('doorlock.ui.action.teleport') : t('doorlock.ui.denied')"
                @click="emit('teleport', row)"
              >
                <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('location')" :key="n" :d="d" /></svg>
              </button>
              <button
                class="icon danger"
                :class="{ off: !access.remove }"
                :disabled="!access.remove"
                :title="access.remove ? t('doorlock.ui.action.delete') : t('doorlock.ui.denied')"
                @click="emit('delete', row)"
              >
                <svg viewBox="0 0 24 24"><path v-for="(d, n) in paths('trash')" :key="n" :d="d" /></svg>
              </button>
            </span>
          </div>
        </li>
      </ul>
    </div>

    <nav v-if="pages > 1" class="pager">
      <button class="step op-frame" data-augmented-ui="tr-clip border" :class="{ 'is-off': page <= 1 }"
        :disabled="page <= 1" :title="t('doorlock.ui.prev')" @click="page -= 1">‹</button>
      <span class="op-value">{{ t('doorlock.ui.page', { page, pages }) }}</span>
      <button class="step op-frame" data-augmented-ui="tr-clip border" :class="{ 'is-off': page >= pages }"
        :disabled="page >= pages" :title="t('doorlock.ui.next')" @click="page += 1">›</button>
    </nav>
  </div>
</template>

<style scoped>
.list {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
  gap: var(--op-space-3);
}

.bar {
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
}

.add,
.step {
  flex: none;
  width: 32px;
  height: 30px;
  border: 0;
  cursor: pointer;
  display: grid;
  place-items: center;
  font: 700 16px / 1 var(--op-font-mono);
}

svg {
  width: 16px;
  height: 16px;
  fill: none;
  stroke: currentcolor;
  stroke-width: 1.9;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.search {
  flex: 1;
  display: flex;
  align-items: center;
  gap: var(--op-space-2);
  padding: 0 var(--op-space-3);
  height: 30px;
  transition: flex-grow var(--op-dur) var(--op-ease);
}

.search:focus-within {
  --aug-border-bg: var(--op-red);
  color: var(--op-red);
}

.search input {
  flex: 1;
  min-width: 0;
  border: 0;
  outline: none;
  background: transparent;
  color: var(--op-text);
}

.count {
  flex: none;
  color: var(--op-text-dim);
}

.table {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
}

.thead,
.row {
  display: grid;
  grid-template-columns: 56px minmax(0, 1fr) 110px 96px 156px;
  align-items: center;
  gap: var(--op-space-2);
}

/* The right pad carries the rows' own extra `--op-space-1` (see `.rows`), or every
   fixed column on the right sat 4px left of its heading. */
.thead {
  padding: 0 calc(var(--op-space-3) + var(--op-space-1)) var(--op-space-2) var(--op-space-3);
  color: var(--op-red-deep);
}

.th {
  border: 0;
  background: none;
  color: inherit;
  font: inherit;
  letter-spacing: inherit;
  text-transform: inherit;
  text-align: left;
  padding: 0;
  cursor: pointer;
  transition: color var(--op-dur-fast) linear;
}

/* A heading sorts, so it answers the pointer like the rest of the panel's controls. */
.th:hover {
  color: var(--op-red);
}

.rows {
  list-style: none;
  margin: 0;
  padding: 0 var(--op-space-1) 0 0;
  display: flex;
  flex-direction: column;
  gap: var(--op-space-1);
  overflow-y: auto;
  min-height: 0;
  /* Scrolled by the wheel, like every list on the surface: no OS scrollbar. */
  scrollbar-width: none;
}

.rows::-webkit-scrollbar {
  width: 0;
  height: 0;
}

.row {
  padding: var(--op-space-2) var(--op-space-3);
}

.c-name {
  font-size: var(--op-fs-body);
}

.tag {
  margin-left: var(--op-space-2);
  color: var(--op-text-dim);
}

.c-state.unlocked {
  color: var(--op-alarm);
}

.c-dist {
  color: var(--op-text-dim);
}

.c-act {
  display: flex;
  justify-content: flex-end;
  gap: var(--op-space-1);
}

.icon {
  border: 0;
  background: none;
  color: var(--op-red-text);
  padding: 3px;
  cursor: pointer;
  display: grid;
  place-items: center;
}

.icon:hover:not(.off) {
  color: var(--op-red);
}

.icon.danger:hover:not(.off) {
  color: var(--op-alarm);
}

.icon.off {
  color: var(--op-text-faint);
  cursor: default;
}

.empty {
  margin: var(--op-space-6) 0;
  text-align: center;
  color: var(--op-text-dim);
}

.pager {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: var(--op-space-3);
  color: var(--op-text-dim);
}
</style>
