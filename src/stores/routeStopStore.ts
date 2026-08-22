import { defineStore } from "pinia"
import { ref } from "vue"
import {
  getStopsByRoute,
  assignStopToRoute,
  updateRouteStop,
  removeStopFromRoute,
  type RouteStop,
  type RouteStopForm,
} from "../services/routeStopService"

export const useRouteStopStore = defineStore("routeStop", () => {
  const stopsByRoute = ref<Record<number, RouteStop[]>>({})
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchByRoute(idroute: number): Promise<RouteStop[]> {
    loading.value = true
    error.value = null
    try {
      const data = await getStopsByRoute(idroute)
      stopsByRoute.value[idroute] = data
      return data
    } catch (err) {
      error.value = "Error al cargar paradas de la ruta"
      console.error(err)
      return []
    } finally {
      loading.value = false
    }
  }

  async function assign(input: RouteStopForm) {
    loading.value = true
    error.value = null
    try {
      await assignStopToRoute(input)
      await fetchByRoute(input.route_id)
      return true
    } catch (err) {
      error.value = "Error al asignar parada"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function update(relId: number, routeId: number, changes: { price?: number; stop_order?: number }) {
    loading.value = true
    error.value = null
    try {
      await updateRouteStop(relId, changes)
      await fetchByRoute(routeId)
      return true
    } catch (err) {
      error.value = "Error al actualizar parada"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function remove(relId: number, idroute: number) {
    loading.value = true
    error.value = null
    try {
      await removeStopFromRoute(relId)
      await fetchByRoute(idroute)
      return true
    } catch (err) {
      error.value = "Error al remover parada"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  function getStops(idroute: number): RouteStop[] {
    return stopsByRoute.value[idroute] ?? []
  }

  function $reset() {
    stopsByRoute.value = {}
    loading.value = false
    error.value = null
  }

  return {
    stopsByRoute,
    loading,
    error,
    fetchByRoute,
    assign,
    update,
    remove,
    getStops,
    $reset,
  }
})
