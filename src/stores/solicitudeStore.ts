import { defineStore } from 'pinia'
import { ref } from 'vue'
import { useAuthStore } from './authStore'
import solicitudeService, { type Solicitude, type SolicitudeInput } from '../services/solicitudeService'

export const useSolicitudeStore = defineStore('solicitude', () => {
  const list = ref<Solicitude[]>([])
  const current = ref<Solicitude | null>(null)
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchPending() {
    const auth = useAuthStore()
    if (!auth.validateSession()) {
      error.value = auth.error
      return false
    }
    loading.value = true
    error.value = null
    try {
      list.value = await solicitudeService.getPendingByClient(auth.idclient)
      return true
    } catch (err) {
      error.value = 'Error al cargar solicitudes pendientes'
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function fetchAll() {
    const auth = useAuthStore()
    if (!auth.validateSession()) {
      error.value = auth.error
      return false
    }
    loading.value = true
    error.value = null
    try {
      list.value = await solicitudeService.getByClient(auth.idclient)
      return true
    } catch (err) {
      error.value = 'Error al cargar solicitudes'
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function create(input: Omit<SolicitudeInput, 'idclient'>) {
    const auth = useAuthStore()
    if (!auth.validateSession()) {
      error.value = auth.error
      return false
    }
    loading.value = true
    error.value = null
    try {
      const record = await solicitudeService.create({
        ...input,
        idclient: auth.idclient,
      })
      list.value.unshift(record)
      return true
    } catch (err) {
      error.value = 'Error al crear la solicitud'
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function cancel(id: number) {
    const auth = useAuthStore()
    if (!auth.validateSession()) {
      error.value = auth.error
      return false
    }
    loading.value = true
    error.value = null
    try {
      await solicitudeService.cancel(id, auth.idclient)
      list.value = list.value.filter((s) => s.id !== id)
      return true
    } catch (err) {
      error.value = 'Error al cancelar la solicitud'
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  function $reset() {
    list.value = []
    current.value = null
    loading.value = false
    error.value = null
  }

  return {
    list,
    current,
    loading,
    error,
    fetchAll,
    fetchPending,
    create,
    cancel,
    $reset,
  }
})
