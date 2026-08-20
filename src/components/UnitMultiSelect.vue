<script setup lang="ts">
import { ref, onMounted } from 'vue'
import MultiSelect from 'primevue/multiselect'
import { getUnitNames } from '@/services/unitService'
import type { UnitName } from '@/services/unitService'

const props = withDefaults(defineProps<{
  modelValue?: (number | null)[] | null
  placeholder?: string
  showClear?: boolean
  filter?: boolean
}>(), {
  modelValue: null,
  placeholder: 'Todas las unidades',
  showClear: true,
  filter: true,
})

const emit = defineEmits<{
  'update:modelValue': [value: (number | null)[] | null]
}>()

const units = ref<UnitName[]>([])
const loading = ref(false)

onMounted(async () => {
  loading.value = true
  try {
    units.value = await getUnitNames()
  } catch (err) {
    console.error('Error loading units:', err)
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
    :options="units"
    :loading="loading"
    optionLabel="name"
    optionValue="id"
    :placeholder="placeholder"
    :showClear="showClear"
    :filter="filter"
    filterPlaceholder="Buscar unidad..."
    :maxSelectedLabels="2"
    @update:modelValue="onSelectChange"
  />
</template>
