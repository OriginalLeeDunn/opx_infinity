<script setup lang="ts">
import { shallowRef } from 'vue'
import { useBridge } from '@/composables/useBridge'
import { useLocale } from '@/composables/useLocale'
import { list, num, table, text, bool } from '@/bridge/types'

interface Hand {
  hand: string
  magazine: number
  capacity: number
  reserve: number
  ammoId: string
  reloading: boolean
}
const hands = shallowRef<Hand[]>([])
const { t } = useLocale()
useBridge('opx:hud:weapons', payload => {
  hands.value = list(table(payload).hands).slice(0, 2).map(value => {
    const row = table(value)
    return { hand: text(row.hand), magazine: num(row.magazine), capacity: num(row.capacity),
      reserve: num(row.reserve), ammoId: text(row.ammoId), reloading: bool(row.reloading) }
  })
})
</script>

<template>
  <div v-if="hands.length" class="weapons">
    <div v-for="(hand, index) in hands" :key="hand.hand" class="hand">
      <span class="op-label">{{ t(`inventory.ui.${hand.hand === 'left' ? 'leftHandLabel' : 'rightHand'}`) }}</span>
      <span class="rounds">{{ hand.magazine }}<small> / {{ hand.capacity }}</small></span>
      <span v-if="hand.reloading" class="op-label">{{ t('inventory.ui.reloading') }}</span>
      <span v-else-if="index === 0 || hand.ammoId !== hands[0]?.ammoId" class="reserve">
        + {{ hand.reserve }}
      </span>
    </div>
  </div>
</template>

<style scoped>
.weapons {
  position: absolute;
  right: 38px;
  bottom: 190px;
  display: flex;
  gap: 24px;
  text-align: right;
  color: var(--op-red);
  pointer-events: none;
}
.hand { display: grid; gap: 4px; }
.rounds { font: 28px var(--op-font-mono, monospace); }
.rounds small, .reserve { font: 14px var(--op-font-mono, monospace); }
</style>
