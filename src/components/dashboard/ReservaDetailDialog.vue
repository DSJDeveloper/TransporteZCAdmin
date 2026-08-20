<script setup lang="ts">
import { ref } from 'vue'
import { supabase } from '@/services/supabaseClient'
import { formatCurrency } from '@/utils/formatters'

interface ReservaRow {
  id: number
  client_name: string
  amount: number
  created_at: string
}

const visible = ref(false)
const loading = ref(false)
const rows = ref<ReservaRow[]>([])
const shedule = ref('')
const dateLabel = ref('')

function formatTime(iso: string): string {
  if (!iso) return ''
  const d = new Date(iso)
  return d.toLocaleTimeString('es-ES', { hour: '2-digit', minute: '2-digit', hour12: true }).toUpperCase()
}

async function open(pShedule: string, pDate: string) {
  shedule.value = pShedule
  const d = new Date(pDate + 'T00:00:00')
  dateLabel.value = d.toLocaleDateString('es-ES', { day: 'numeric', month: 'long', year: 'numeric' })
  visible.value = true
  loading.value = true
  try {
    const { data } = await supabase.rpc('get_reservas_detail', {
      p_date: pDate,
      p_shedule: pShedule,
    })
    rows.value = (data || []) as ReservaRow[]
  } catch (err) {
    console.error('Error loading reserva detail:', err)
    rows.value = []
  } finally {
    loading.value = false
  }
}

function close() {
  visible.value = false
}

defineExpose({ open })
</script>

<template>
  <Teleport to="body">
    <div
      v-if="visible"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/30"
      @click.self="close"
    >
      <div class="bg-surface-container-lowest rounded-xl shadow-xl border border-outline-variant w-full max-w-lg mx-md max-h-[80vh] flex flex-col">
        <!-- header -->
        <div class="flex items-center justify-between px-lg py-md border-b border-outline-variant">
          <div>
            <h3 class="font-headline-sm text-headline-sm text-on-surface">
              Reservas — {{ shedule }}
            </h3>
            <p class="text-body-md text-on-surface-variant">{{ dateLabel }}</p>
          </div>
          <button
            class="text-outline hover:text-on-surface p-xs rounded-full hover:bg-surface-container transition-colors"
            @click="close"
          >
            <span class="material-symbols-outlined">close</span>
          </button>
        </div>

        <!-- body -->
        <div class="flex-1 overflow-y-auto p-lg space-y-md">
          <div v-if="loading" class="text-center text-on-surface-variant py-lg">
            <span class="material-symbols-outlined animate-spin align-middle">refresh</span>
            Cargando...
          </div>

          <div v-else-if="rows.length === 0" class="text-center text-on-surface-variant py-lg">
            Sin reservas para este horario
          </div>

          <div v-else class="space-y-sm">
            <div
              v-for="(r, i) in rows"
              :key="r.id"
              class="flex items-center justify-between p-md rounded-lg border border-outline-variant hover:bg-surface-container-low transition-colors"
              :class="{ 'border-tertiary/30': i === 0 }"
            >
              <div class="flex items-center gap-md min-w-0">
                <span class="w-8 h-8 rounded-full bg-primary-container/10 flex items-center justify-center shrink-0">
                  <span class="material-symbols-outlined !text-sm text-primary">person</span>
                </span>
                <div class="min-w-0">
                  <p class="font-bold text-on-surface truncate">{{ r.client_name || 'Sin nombre' }}</p>
                  <p class="text-label-md text-outline">{{ formatTime(r.created_at) }}</p>
                </div>
              </div>
              <span class="font-bold text-on-surface shrink-0 ml-md">{{ formatCurrency(r.amount) }}</span>
            </div>
          </div>
        </div>

        <!-- footer -->
        <div class="px-lg py-md border-t border-outline-variant flex justify-end">
          <button
            class="px-md py-sm bg-primary text-white rounded-lg text-label-md font-bold hover:bg-primary/90 transition-colors"
            @click="close"
          >
            Cerrar
          </button>
        </div>
      </div>
    </div>
  </Teleport>
</template>
