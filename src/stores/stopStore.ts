import { defineStore } from "pinia"
import { ref } from "vue"
import {
  getStops,
  createStop,
  updateStop,
  deleteStop,
  type Stop,
  type StopForm,
} from "../services/stopService"

export const useStopStore = defineStore("stop", () => {
  const list = ref<Stop[]>([])
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      list.value = await getStops()
      return true
    } catch (err) {
      error.value = "Error al cargar las paradas"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function create(input: StopForm) {
    loading.value = true
    error.value = null
    try {
      const record = await createStop(input)
      list.value.push(record)
      return true
    } catch (err) {
      error.value = "Error al crear la parada"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function update(id: number, input: Partial<StopForm>) {
    loading.value = true
    error.value = null
    try {
      const record = await updateStop(id, input)
      const idx = list.value.findIndex((s) => s.id === id)
      if (idx !== -1) {
        list.value[idx] = record
      }
      return true
    } catch (err) {
      error.value = "Error al actualizar la parada"
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
      await deleteStop(id)
      list.value = list.value.filter((s) => s.id !== id)
      return true
    } catch (err) {
      error.value = "Error al eliminar la parada"
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
