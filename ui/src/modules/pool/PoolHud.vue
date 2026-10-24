<script setup lang="ts">
import { computed, onUnmounted, ref } from 'vue'
import { num, text } from '@/bridge/types'
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
    <template v-if="!rolling">
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
.hint { margin: 10px 0 0; color: var(--op-text-faint); text-align: center; }
.charging .hint { color: var(--op-red-text); }
</style>
