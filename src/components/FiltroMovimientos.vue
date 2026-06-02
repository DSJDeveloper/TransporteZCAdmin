<script setup lang="ts">
import { ref, computed, watch, onMounted } from 'vue'
import DatePicker from 'primevue/datepicker'
import Select from 'primevue/select'
import Button from 'primevue/button'
import { toDate, toStr } from '@/utils/formatters'

export interface FiltrosMovimientos {
  fechaInicio: string
  fechaFin: string
  status: number | null
}

// 1. Añadimos showStatus a las props manteniendo modelValue
const props = withDefaults(defineProps<{
  modelValue?: FiltrosMovimientos
  showStatus?: boolean
}>(), {
  modelValue: () => ({
    fechaInicio: '',
    fechaFin: '',
    status: null,
  }),
  showStatus: true // Por defecto se muestra
})

const emit = defineEmits<{
  'update:modelValue': [value: FiltrosMovimientos]
  'filtrar': [value: FiltrosMovimientos]
}>()

const local = ref<FiltrosMovimientos>({ ...props.modelValue })

watch(() => props.modelValue, (val) => {
  local.value = { ...val }
}, { deep: true })


// 2. Lógica para calcular las fechas por defecto del mes actual
const hoy = new Date()
const primerDiaMes = new Date(hoy.getFullYear(), hoy.getMonth(), 1)

// Asignamos los valores por defecto si vienen vacíos de las props
if (!local.value.fechaInicio) local.value.fechaInicio = toStr(primerDiaMes)
if (!local.value.fechaFin) local.value.fechaFin = toStr(hoy)

const fechaInicio = computed({
  get: () => toDate(local.value.fechaInicio),
  set: (val) => { local.value.fechaInicio = toStr(val) },
})
const fechaFin = computed({
  get: () => toDate(local.value.fechaFin),
  set: (val) => { local.value.fechaFin = toStr(val) },
})

const opcionesStatus = [
  { label: 'Todos los estados', value: null },
  { label: 'Aprobado', value: 0 },
  { label: 'Rechazado', value: 1 },
]

function aplicarFiltros() {
  const payload = { ...local.value }
  emit('update:modelValue', payload)
  emit('filtrar', payload)
}

// Al limpiar filtros volvemos a poner las fechas por defecto solicitadas
function limpiarFiltros() {
  local.value = { 
    fechaInicio: toStr(primerDiaMes), 
    fechaFin: toStr(hoy), 
    status: null 
  }
  aplicarFiltros()
}

// Emitir el estado inicial al montar el componente
onMounted(() => {
  aplicarFiltros()
})
</script>

<template>
  <div class="grid grid-cols-1 md:grid-cols-4 gap-2 bg-surface-container-low p-2 rounded-xl border border-outline-variant/30">
    <div class="md:col-span-3 flex flex-col sm:flex-row gap-2">
      <DatePicker
        v-model="fechaInicio"
        dateFormat="dd/mm/yy"
        mask="99/99/9999"
        placeholder="Fecha inicio"
        showIcon
        iconDisplay="input"
        class="flex-1"
      />
      <DatePicker
        v-model="fechaFin"
        dateFormat="dd/mm/yy"
        mask="99/99/9999"
        placeholder="Fecha fin"
        showIcon
        iconDisplay="input"
        class="flex-1"
      />
      
      <Select
        v-if="showStatus"
        v-model="local.status"
        :options="opcionesStatus"
        optionLabel="label"
        optionValue="value"
        placeholder="Estado"
        class="flex-1"
        showClear
      />
    </div>
    <div class="flex gap-2">
      <Button
        label="Buscar"
        icon="pi pi-search"
        class="flex-1 !bg-primary-container !text-on-primary-container border-none py-3 rounded-lg justify-center text-label-md font-bold shadow-sm"
        @click="aplicarFiltros"
      />
      <Button
        icon="pi pi-eraser"
        class="!bg-surface-container-high !text-on-surface-variant border-none py-3 rounded-lg justify-center w-12"
        @click="limpiarFiltros"
      />
    </div>
  </div>
</template>