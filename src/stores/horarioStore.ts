import { defineStore } from "pinia"
import { ref } from "vue"
import {
  getHorarios,
  createHorario,
  updateHorario,
  deleteHorario,
  type Horario,
  type HorarioForm,
} from "../services/horarioService"

export const useHorarioStore = defineStore("horario", () => {
  const list = ref<Horario[]>([])
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      list.value = await getHorarios()
      return true
    } catch (err) {
      error.value = "Error al cargar los horarios"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function create(input: HorarioForm) {
    loading.value = true
    error.value = null
    try {
      const record = await createHorario(input)
      list.value.push(record)
      return true
    } catch (err) {
      error.value = "Error al crear el horario"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function update(id: number, input: Partial<HorarioForm>) {
    loading.value = true
    error.value = null
    try {
      const record = await updateHorario(id, input)
      const idx = list.value.findIndex((h) => h.id === id)
      if (idx !== -1) {
        list.value[idx] = record
      }
      return true
    } catch (err) {
      error.value = "Error al actualizar el horario"
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
      await deleteHorario(id)
      list.value = list.value.filter((h) => h.id !== id)
      return true
    } catch (err) {
      error.value = "Error al eliminar el horario"
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
