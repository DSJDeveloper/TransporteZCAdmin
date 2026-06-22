import { defineStore } from "pinia"
import { ref } from "vue"
import {
  getCareers,
  createCareer,
  updateCareer,
  deleteCareer,
  type Career,
  type CareerForm,
} from "../services/careerService"

export const useCareerStore = defineStore("career", () => {
  const list = ref<Career[]>([])
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      list.value = await getCareers()
      return true
    } catch (err) {
      error.value = "Error al cargar las carreras"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function create(input: CareerForm) {
    loading.value = true
    error.value = null
    try {
      const record = await createCareer(input)
      list.value.push(record)
      return true
    } catch (err) {
      error.value = "Error al crear la carrera"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function update(id: number, input: Partial<CareerForm>) {
    loading.value = true
    error.value = null
    try {
      const record = await updateCareer(id, input)
      const idx = list.value.findIndex((c) => c.id === id)
      if (idx !== -1) {
        list.value[idx] = record
      }
      return true
    } catch (err) {
      error.value = "Error al actualizar la carrera"
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
      await deleteCareer(id)
      list.value = list.value.filter((c) => c.id !== id)
      return true
    } catch (err) {
      error.value = "Error al eliminar la carrera"
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
