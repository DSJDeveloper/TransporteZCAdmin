<script setup lang="ts">
import { ref, onMounted } from 'vue'
import MultiSelect from 'primevue/multiselect'
import { getHorariosRpc } from '@/services/horarioService'
import type { HorarioName } from '@/services/horarioService'

const props = withDefaults(defineProps<{
  modelValue?: (number | null)[] | null
  placeholder?: string
  showClear?: boolean
  filter?: boolean
}>(), {
  modelValue: null,
  placeholder: 'Todos los horarios',
  showClear: true,
  filter: true,
})

const emit = defineEmits<{
  'update:modelValue': [value: (number | null)[] | null]
}>()

const horarios = ref<HorarioName[]>([])
const loading = ref(false)

onMounted(async () => {
  loading.value = true
  try {
    horarios.value = await getHorariosRpc()
  } catch (err) {
    console.error('Error loading horarios:', err)
  } finally {
    loading.value = false
  }
})

function onSelectChange(val: (number | null)[] | null) {
  emit('update:modelValue', val)
}
</script>

<template>
  <MultiSelect
    :modelValue="modelValue"
    :options="horarios"
    :loading="loading"
    optionLabel="shudle"
    optionValue="id"
    :placeholder="placeholder"
    :showClear="showClear"
    :filter="filter"
    filterPlaceholder="Buscar horario..."
    :maxSelectedLabels="2"
    @update:modelValue="onSelectChange"
  >
    <template #option="slotProps">
      <span>{{ slotProps.option.shudle }}</span>
    </template>
  </MultiSelect>
</template>
