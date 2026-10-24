<script setup lang="ts">
import { computed, onUnmounted, ref } from 'vue'
import { list, num, text } from '@/bridge/types'
import { useBridge } from '@/composables/useBridge'

// Presentation only. Lua owns the input and the server accepts the shot.
const visible = ref(false)
const title = ref('')
const hint = ref('')
const view = ref('')
const label = ref('')
const power = ref(0)
const rolling = ref(false)
const charging = ref(false)
const canShoot = ref(false)
const mode = ref('')
const status = ref('')
const duel = ref(false)
const score = ref([0, 0])
const labels = ref(['', ''])
const turn = ref(0)
const race = ref('')
const soloStats = ref('')
const percent = computed(() => Math.round(power.value * 100))
let seen = 0
useBridge('opx:pool:frame', (payload) => {
  title.value = text(payload.title).slice(0, 48)
  hint.value = text(payload.hint).slice(0, 160)
  view.value = text(payload.view).slice(0, 48)
  label.value = text(payload.powerLabel).slice(0, 48)
  power.value = Math.max(0, Math.min(1, num(payload.power)))
  rolling.value = payload.phase === 'rolling'
  charging.value = payload.charging === true
  canShoot.value = payload.canShoot === true
  mode.value = text(payload.modeLabel)
  status.value = text(payload.status).slice(0, 180)
  duel.value = payload.duel === true
  const raw = list(payload.score)
  score.value = [0, 1].map(i => Math.max(0, Math.min(1000000, Math.floor(num(raw[i])))))
  labels.value = [text(payload.firstLabel), text(payload.secondLabel)]
  turn.value = num(payload.turn)
  race.value = text(payload.raceLabel)
  soloStats.value = text(payload.soloStats)
  seen = Date.now()
  visible.value = true
})
useBridge('opx:pool:hide', () => { visible.value = false })
// A stopped Lua frame or a missed hide must never leave a stale power reading.
const sweep = setInterval(() => {
  if (visible.value && Date.now() - seen > 500) visible.value = false
}, 150)
onUnmounted(() => clearInterval(sweep))
</script>

<template>
  <section v-if="visible" class="pool op-plane op-ink" :class="{ charging }">
    <div class="heading op-eyebrow">
      <span class="op-truncate">{{ title }}</span>
      <span v-if="!rolling">{{ view }}</span>
    </div>
    <p class="mode op-eyebrow">{{ mode }}</p>
    <div v-if="duel" class="scoreboard">
      <div v-for="(points, slot) in score" :key="slot" class="seat" :class="{ active: turn === slot + 1 }">
        <span class="op-eyebrow">{{ labels[slot] }}</span><strong class="op-value">{{ points }}</strong>
      </div>
      <span class="race op-eyebrow">{{ race }}</span>
    </div>
    <p v-else class="stats op-eyebrow">{{ soloStats }}</p>
    <p class="status op-eyebrow">{{ status }}</p>
    <template v-if="!rolling && canShoot">
      <div class="reading"><span class="op-eyebrow">{{ label }}</span><strong class="op-value">{{ percent }}<small>%</small></strong></div>
      <div class="track" role="meter" :aria-label="label" :aria-valuenow="percent" aria-valuemin="0" aria-valuemax="100">
        <span class="fill" :style="{ transform: `scaleX(${power})` }" />
        <i v-for="tick in 3" :key="tick" :style="{ left: `${tick * 25}%` }" />
      </div>
    </template>
    <p class="hint op-eyebrow">{{ hint }}</p>
  </section>
</template>

<style scoped>
.pool { position: absolute; left: 50%; bottom: calc(var(--op-inset-y) + 100px); transform: translateX(-50%); width: 300px; pointer-events: none; }
.heading, .reading { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; }
.heading { color: var(--op-text-faint); margin-bottom: 10px; }
.reading { color: var(--op-red-text); }
.reading strong { font-size: 32px; line-height: 1; font-weight: 500; }
.reading small { font-size: 14px; padding-left: 3px; }
.track { position: relative; height: 10px; padding: 2px; margin-top: 7px; border: 1px solid var(--op-red-idle); }
.fill { display: block; height: 100%; background: var(--op-red); transform-origin: left; transition: transform 55ms linear; }
.track i { position: absolute; top: 0; bottom: 0; width: 1px; background: var(--op-red-idle); }
.mode, .stats, .status { margin: 6px 0; text-align: center; }
.mode { color: var(--op-red-text); }
.stats, .race { color: var(--op-text-faint); }
.status { color: var(--op-red-text); }
.scoreboard { display: grid; grid-template-columns: 1fr 1fr; gap: 4px 20px; margin-bottom: 8px; }
.seat { display: flex; justify-content: space-between; align-items: baseline; border-bottom: 1px solid var(--op-red-idle); }
.seat.active { color: var(--op-red-text); border-color: var(--op-red); }
.seat strong { font-size: 28px; }
.race { grid-column: 1 / -1; text-align: center; }
.hint { margin: 10px 0 0; color: var(--op-text-faint); text-align: center; }
.charging .hint { color: var(--op-red-text); }
</style>
