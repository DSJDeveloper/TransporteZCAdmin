<script setup lang="ts">
import { ref, onMounted } from 'vue'
import MultiSelect from 'primevue/multiselect'
import { getRouteNames } from '@/services/routeService'
import type { RouteName } from '@/services/routeService'

const props = withDefaults(defineProps<{
  modelValue?: (number | null)[] | null
  placeholder?: string
  showClear?: boolean
  filter?: boolean
}>(), {
  modelValue: null,
  placeholder: 'Todas las rutas',
  showClear: true,
  filter: true,
})

const emit = defineEmits<{
  'update:modelValue': [value: (number | null)[] | null]
}>()

const routes = ref<RouteName[]>([])
const loading = ref(false)

onMounted(async () => {
  loading.value = true
  try {
    routes.value = await getRouteNames()
  } catch (err) {
    console.error('Error loading routes:', err)
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
    :options="routes"
    :loading="loading"
    optionLabel="description"
    optionValue="id"
    :placeholder="placeholder"
    :showClear="showClear"
    :filter="filter"
    filterPlaceholder="Buscar ruta..."
    :maxSelectedLabels="2"
    @update:modelValue="onSelectChange"
  >
    <template #option="slotProps">
      <span>{{ slotProps.option.code }} - {{ slotProps.option.description }}</span>
    </template>
  </MultiSelect>
</template>
