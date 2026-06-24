<script setup lang="ts">
import { ref } from 'vue'
import { supabase } from '@/services/supabaseClient'
import { downloadCSV } from '@/utils/exportCsv'

const props = defineProps<{
  limit?: number
}>()

interface Movement {
  id: number
  type: 'transaction' | 'recharge'
  description: string
  amount: number
  created_at: string
  client_name: string
}

const movements = ref<Movement[]>([])
const loading = ref(false)

function formatTime(iso: string): string {
  if (!iso) return ''
  const d = new Date(iso)
  const now = new Date()
  const isToday = d.toDateString() === now.toDateString()
  const yesterday = new Date(now)
  yesterday.setDate(yesterday.getDate() - 1)
  const isYesterday = d.toDateString() === yesterday.toDateString()

  const time = d.toLocaleTimeString('es-ES', { hour: '2-digit', minute: '2-digit', hour12: true }).toUpperCase()
  if (isToday) return `HOY, ${time}`
  if (isYesterday) return `AYER, ${time}`
  return d.toLocaleDateString('es-ES', { day: 'numeric', month: 'short' }).toUpperCase() + `, ${time}`
}

function formatAmount(n: number): string {
  const sign = n >= 0 ? '+' : ''
  return sign + '$' + Math.abs(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function getMovementIcon(type: string): string {
  return type === 'recharge' ? 'payments' : 'swap_horiz'
}

function getMovementIconBg(type: string): string {
  return type === 'recharge' ? 'bg-tertiary-container/10' : 'bg-primary-container/10'
}

function getMovementIconColor(type: string): string {
  return type === 'recharge' ? 'text-tertiary' : 'text-primary'
}

function getAmountColor(type: string): string {
  return type === 'recharge' ? 'text-tertiary' : 'text-on-surface'
}

async function load() {
  loading.value = true
  try {
    const { data } = await supabase.rpc('get_recent_movements', { p_limit: props.limit ?? 5 })
    movements.value = (data || []) as Movement[]
  } catch (err) {
    console.error('Error loading movements:', err)
  } finally {
    loading.value = false
  }
}

function exportCSV() {
  downloadCSV(
    movements.value as unknown as Record<string, unknown>[],
    'movimientos-recientes',
    [
      { key: 'id', label: 'ID' },
      { key: 'client_name', label: 'Cliente' },
      { key: 'type', label: 'Tipo' },
      { key: 'description', label: 'Descripción' },
      { key: 'amount', label: 'Monto' },
      { key: 'created_at', label: 'Fecha' },
    ],
  )
}

defineExpose({ load })
</script>

<template>
  <div class="lg:col-span-3 bg-surface-container-lowest border border-outline-variant rounded-xl p-lg shadow-sm">
    <div class="flex justify-between items-center mb-lg">
      <h3 class="font-headline-sm text-headline-sm text-on-surface">Movimientos Recientes</h3>
      <div class="flex gap-md">
        <button
          class="text-label-md font-bold text-on-surface-variant border border-outline-variant px-md py-1 rounded hover:bg-surface-container transition-colors disabled:opacity-40"
          :disabled="movements.length === 0"
          @click="exportCSV"
        >
          Exportar CSV
        </button>
        <button class="text-label-md font-bold text-on-surface-variant border border-outline-variant px-md py-1 rounded hover:bg-surface-container transition-colors">
          Imprimir
        </button>
      </div>
    </div>

    <div v-if="loading" class="space-y-gutter">
      <div v-for="i in 3" :key="i" class="flex items-center gap-md p-md">
        <div class="w-12 h-12 rounded-full bg-surface-container animate-pulse shrink-0" />
        <div class="flex-1 space-y-xs">
          <div class="h-4 w-48 rounded bg-surface-container animate-pulse" />
          <div class="h-3 w-32 rounded bg-surface-container animate-pulse" />
        </div>
        <div class="text-right space-y-xs">
          <div class="h-4 w-20 rounded bg-surface-container animate-pulse" />
          <div class="h-3 w-24 rounded bg-surface-container animate-pulse" />
        </div>
      </div>
    </div>

    <div v-else-if="movements.length === 0" class="text-center text-on-surface-variant py-lg">
      Sin movimientos recientes
    </div>

    <div v-else class="space-y-gutter">
      <div
        v-for="(mv, i) in movements"
        :key="i"
        class="flex items-center gap-md p-md hover:bg-surface-container-low rounded-lg transition-all border border-transparent hover:border-outline-variant"
      >
        <div
          class="w-12 h-12 rounded-full flex items-center justify-center shrink-0"
          :class="getMovementIconBg(mv.type)"
        >
          <span class="material-symbols-outlined" :class="getMovementIconColor(mv.type)">
            {{ getMovementIcon(mv.type) }}
          </span>
        </div>
        <div class="flex-1 min-w-0">
          <p class="font-bold text-on-surface truncate">{{ mv.client_name || 'Sin cliente' }}</p>
          <p class="text-body-md text-on-surface-variant truncate">{{ mv.description }}</p>
        </div>
        <div class="text-right shrink-0">
          <p class="font-bold" :class="getAmountColor(mv.type)">{{ formatAmount(mv.amount) }}</p>
          <p class="text-[10px] text-outline uppercase font-semibold">{{ formatTime(mv.created_at) }}</p>
        </div>
      </div>
    </div>
  </div>
</template>
