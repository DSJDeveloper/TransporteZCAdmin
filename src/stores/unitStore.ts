import { defineStore } from "pinia"
import { ref } from "vue"
import { getUnits, createUnit, updateUnit, deleteUnit, type Unit, type UnitForm } from "../services/unitService"

export const useUnitStore = defineStore("unit", () => {
  const list = ref<Unit[]>([])
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      list.value = await getUnits()
      return true
    } catch (err) {
      error.value = "Error al cargar las unidades"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function create(input: UnitForm) {
    loading.value = true
    error.value = null
    try {
      const record = await createUnit(input)
      list.value.push(record)
      return true
    } catch (err) {
      error.value = "Error al crear la unidad"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function update(id: number, input: Partial<UnitForm>) {
    loading.value = true
    error.value = null
    try {
      const record = await updateUnit(id, input)
      const idx = list.value.findIndex((u) => u.id === id)
      if (idx !== -1) {
        list.value[idx] = record
      }
      return true
    } catch (err) {
      error.value = "Error al actualizar la unidad"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function remove(id: number) {
    loading.value = true
    error.value = null
    try {
      await deleteUnit(id)
      list.value = list.value.filter((u) => u.id !== id)
      return true
    } catch (err) {
      error.value = "Error al eliminar la unidad"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  function $reset() {
    list.value = []
    loading.value = false
    error.value = null
  }

  return {
    list,
    loading,
    error,
    fetchAll,
    create,
    update,
    remove,
    $reset,
  }
})
