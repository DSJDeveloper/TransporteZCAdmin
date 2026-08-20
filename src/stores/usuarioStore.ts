import { defineStore } from "pinia"
import { ref } from "vue"
import {
  getUsuarios,
  createUsuario,
  updateUsuario,
  deleteUsuario,
  type Usuario,
  type UsuarioCreate,
  type UsuarioUpdate,
} from "../services/usuarioService"

export const useUsuarioStore = defineStore("usuario", () => {
  const list = ref<Usuario[]>([])
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      list.value = await getUsuarios()
      return true
    } catch (err) {
      error.value = "Error al cargar los usuarios"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function create(input: UsuarioCreate) {
    loading.value = true
    error.value = null
    try {
      const record = await createUsuario(input)
      list.value.push(record)
      return true
    } catch (err) {
      error.value = "Error al crear el usuario"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function update(id: string, input: UsuarioUpdate) {
    loading.value = true
    error.value = null
    try {
      const record = await updateUsuario(id, input)
      const idx = list.value.findIndex((u) => u.id === id)
      if (idx !== -1) {
        list.value[idx] = record
      }
      return true
    } catch (err) {
      error.value = "Error al actualizar el usuario"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function remove(id: string) {
    loading.value = true
    error.value = null
    try {
      await deleteUsuario(id)
      list.value = list.value.filter((u) => u.id !== id)
      return true
    } catch (err) {
      error.value = "Error al eliminar el usuario"
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
