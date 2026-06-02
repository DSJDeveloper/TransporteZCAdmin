import { defineStore } from "pinia"
import { ref } from "vue"
import { getClients, createClient, updateClient, deleteClient, type Client, type ClientForm } from "../services/clientService"

export const useClientStore = defineStore("client", () => {
  const list = ref<Client[]>([])
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      list.value = await getClients()
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
      const record = await createClient(input)
      list.value.push(record)
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
      const record = await updateClient(id, input)
      const idx = list.value.findIndex((c) => c.id === id)
      if (idx !== -1) {
        list.value[idx] = record
      }
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
      list.value = list.value.filter((c) => c.id !== id)
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
