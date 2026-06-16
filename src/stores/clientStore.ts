import { defineStore } from "pinia"
import { ref } from "vue"
import { getClientsPaginated, createClient, updateClient, deleteClient, type Client, type ClientForm, type PaginatedClientsParams } from "../services/clientService"

export const useClientStore = defineStore("client", () => {
  const records = ref<Client[]>([])
  const total = ref(0)
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchAll(params: PaginatedClientsParams) {
    loading.value = true
    error.value = null
    try {
      const result = await getClientsPaginated(params)
      records.value = result.data
      total.value = result.total
      return true
    } catch (err) {
      error.value = "Error al cargar los clientes"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function create(input: ClientForm) {
    loading.value = true
    error.value = null
    try {
      await createClient(input)
      return true
    } catch (err) {
      error.value = "Error al crear el cliente"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function update(id: number, input: Partial<ClientForm>) {
    loading.value = true
    error.value = null
    try {
      await updateClient(id, input)
      return true
    } catch (err) {
      error.value = "Error al actualizar el cliente"
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
      await deleteClient(id)
      return true
    } catch (err) {
      error.value = "Error al eliminar el cliente"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  function $reset() {
    records.value = []
    total.value = 0
    loading.value = false
    error.value = null
  }

  return {
    records,
    total,
    loading,
    error,
    fetchAll,
    create,
    update,
    remove,
    $reset,
  }
})
