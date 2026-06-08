import { defineStore } from "pinia"
import { ref } from "vue"
import {
  getHorariosByRoute,
  assignHorarioToRoute,
  removeHorarioFromRoute,
  type RouteHorario,
} from "../services/routeHorarioService"

export const useRouteHorarioStore = defineStore("routeHorario", () => {
  const horariosByRoute = ref<Record<number, RouteHorario[]>>({})
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchByRoute(idroute: number): Promise<RouteHorario[]> {
    loading.value = true
    error.value = null
    try {
      const data = await getHorariosByRoute(idroute)
      horariosByRoute.value[idroute] = data
      return data
    } catch (err) {
      error.value = "Error al cargar horarios de la ruta"
      console.error(err)
      return []
    } finally {
      loading.value = false
    }
  }

  async function assign(idroute: number, idhorario: number) {
    loading.value = true
    error.value = null
    try {
      await assignHorarioToRoute(idroute, idhorario)
      await fetchByRoute(idroute)
      return true
    } catch (err) {
      error.value = "Error al asignar horario"
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
      await removeHorarioFromRoute(relId)
      await fetchByRoute(idroute)
      return true
    } catch (err) {
      error.value = "Error al remover horario"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  function getHorarios(idroute: number): RouteHorario[] {
    return horariosByRoute.value[idroute] ?? []
  }

  function $reset() {
    horariosByRoute.value = {}
    loading.value = false
    error.value = null
  }

  return {
    horariosByRoute,
    loading,
    error,
    fetchByRoute,
    assign,
    remove,
    getHorarios,
    $reset,
  }
})
