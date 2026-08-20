import { defineStore } from "pinia"
import { ref } from "vue"
import {
  getRoutes,
  createRoute,
  updateRoute,
  deleteRoute,
  type Route,
  type RouteForm,
} from "../services/routeService"

export const useRouteStore = defineStore("route", () => {
  const list = ref<Route[]>([])
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      list.value = await getRoutes()
      return true
    } catch (err) {
      error.value = "Error al cargar las rutas"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function create(input: RouteForm) {
    loading.value = true
    error.value = null
    try {
      const record = await createRoute(input)
      list.value.push(record)
      return true
    } catch (err) {
      error.value = "Error al crear la ruta"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function update(id: number, input: Partial<RouteForm>) {
    loading.value = true
    error.value = null
    try {
      const record = await updateRoute(id, input)
      const idx = list.value.findIndex((r) => r.id === id)
      if (idx !== -1) {
        list.value[idx] = record
      }
      return true
    } catch (err) {
      error.value = "Error al actualizar la ruta"
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
      await deleteRoute(id)
      list.value = list.value.filter((r) => r.id !== id)
      return true
    } catch (err) {
      error.value = "Error al eliminar la ruta"
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
