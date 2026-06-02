<script setup lang="ts">
import { ref, computed } from 'vue'
import DatePicker from 'primevue/datepicker'
import { toDate, toStr } from '@/utils/formatters'

export interface FiltroRango {
  fechaInicio: string
  fechaFin: string
}

const props = withDefaults(defineProps<{
  modelValue?: FiltroRango
}>(), {
  modelValue: () => ({ fechaInicio: '', fechaFin: '' }),
})

const emit = defineEmits<{
  'update:modelValue': [value: FiltroRango]
  'filtrar': [value: FiltroRango]
}>()

const local = ref<FiltroRango>({ ...props.modelValue })

const fechaInicio = computed({
  get: () => toDate(local.value.fechaInicio),
  set: (val) => { local.value.fechaInicio = toStr(val) },
})
const fechaFin = computed({
  get: () => toDate(local.value.fechaFin),
  set: (val) => { local.value.fechaFin = toStr(val) },
})

function aplicar() {
  const payload = { ...local.value }
  emit('update:modelValue', payload)
  emit('filtrar', payload)
}

function limpiar() {
  local.value = { fechaInicio: '', fechaFin: '' }
  emit('update:modelValue', { fechaInicio: '', fechaFin: '' })
  emit('filtrar', { fechaInicio: '', fechaFin: '' })
}
</script>

<template>
  <div class="flex items-center gap-2">
    <DatePicker
      v-model="fechaInicio"
      dateFormat="dd/mm/yy"
      mask="99/99/9999"
      placeholder="Fecha inicio"
      showIcon
      iconDisplay="input"
      class="flex-1"
    />
    <span class="text-outline shrink-0 text-body-md">al</span>
    <DatePicker
      v-model="fechaFin"
      dateFormat="dd/mm/yy"
      mask="99/99/9999"
      placeholder="Fecha fin"
      showIcon
      iconDisplay="input"
      class="flex-1"
    />
    <Button
      icon="pi pi-search"
      class="!bg-primary !text-on-primary border-none h-10 w-10 rounded-xl"
      @click="aplicar"
    />
    <Button
      icon="pi pi-eraser"
      class="!bg-surface-container-high !text-on-surface-variant border-none h-10 w-10 rounded-xl"
      @click="limpiar"
    />
  </div>
</template>
