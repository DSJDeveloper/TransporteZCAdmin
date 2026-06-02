<script setup lang="ts">
import { ref, watch } from 'vue'
import { supabase } from '@/services/supabaseClient'

const props = defineProps<{
  date?: string
}>()
const emit = defineEmits<{
  (e: 'update:date', val: string): void
  (e: 'view-detail', shedule: string, date: string): void
}>()

const rows = ref<{ shedule: string; count: number }[]>([])
const loading = ref(false)
const today = new Date().toISOString().split('T')[0] ?? ''
const innerDate = ref(today)

if (props.date) innerDate.value = props.date

watch(() => props.date, (v) => {
  if (v) innerDate.value = v
})

async function load() {
  loading.value = true
  try {
    const { data } = await supabase.rpc('get_daily_reservas', { p_date: innerDate.value || null })
    rows.value = (data || []) as { shedule: string; count: number }[]
  } catch (err) {
    console.error('Error loading reservas:', err)
    rows.value = []
  } finally {
    loading.value = false
  }
}

function filter() {
  emit('update:date', innerDate.value)
  load()
}

defineExpose({ load })
</script>

<template>
  <div class="bg-surface-container-lowest border border-outline-variant rounded-xl overflow-hidden shadow-sm">
    <div class="p-lg border-b border-outline-variant flex items-center justify-between flex-wrap gap-sm">
      <div class="flex items-center gap-md">
        <span class="material-symbols-outlined text-primary">schedule</span>
        <h3 class="font-headline-sm text-headline-sm text-on-surface">Reservas Diarias</h3>
      </div>
      <div class="flex gap-xs items-center">
        <input
          v-model="innerDate"
          type="date"
          class="border border-outline-variant rounded px-sm py-1 text-body-md bg-transparent"
        />
        <button
          class="bg-primary text-white px-md py-1 rounded-lg text-label-md font-bold hover:bg-primary/90 transition-colors disabled:opacity-50"
          :disabled="loading"
          @click="filter"
        >
          <span v-if="loading" class="material-symbols-outlined !text-sm animate-spin">refresh</span>
          <span v-else>Filtrar</span>
        </button>
      </div>
    </div>

    <div class="overflow-x-auto">
      <table class="w-full text-left">
        <thead class="bg-surface-container text-on-surface-variant font-label-md uppercase tracking-tighter">
          <tr>
            <th class="px-lg py-md">HORARIO</th>
            <th class="px-lg py-md">CANTIDAD</th>
            <th class="px-lg py-md text-right">ACCIONES</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-outline-variant">
          <tr v-if="loading" class="hover:bg-surface-container-low transition-colors">
            <td colspan="3" class="px-lg py-md text-center text-on-surface-variant">
              <span class="material-symbols-outlined animate-spin align-middle">refresh</span>
              Cargando...
            </td>
          </tr>
          <tr v-else-if="rows.length === 0" class="hover:bg-surface-container-low transition-colors">
            <td colspan="3" class="px-lg py-md text-center text-on-surface-variant">
              Sin reservas para esta fecha
            </td>
          </tr>
          <tr
            v-for="(r, i) in rows"
            :key="i"
            class="hover:bg-surface-container-low transition-colors"
          >
            <td class="px-lg py-md font-bold text-on-surface">{{ r.shedule }}</td>
            <td class="px-lg py-md">{{ r.count }}</td>
            <td class="px-lg py-md text-right">
              <button
                class="text-primary hover:bg-primary-container/10 p-xs rounded-full"
                @click="emit('view-detail', r.shedule, innerDate)"
              >
                <span class="material-symbols-outlined">visibility</span>
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
