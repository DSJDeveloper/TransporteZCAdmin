import { defineStore } from "pinia"
import { ref } from "vue"
import {
  getBankInfoList,
  createBankInfo,
  updateBankInfo,
  deleteBankInfo,
  type BankInfo,
  type BankInfoForm,
} from "../services/bankInfoService"

export const useBankInfoStore = defineStore("bankInfo", () => {
  const list = ref<BankInfo[]>([])
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      list.value = await getBankInfoList()
      return true
    } catch (err) {
      error.value = "Error al cargar la informacion bancaria"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function create(input: BankInfoForm) {
    loading.value = true
    error.value = null
    try {
      const record = await createBankInfo(input)
      list.value.push(record)
      return true
    } catch (err) {
      error.value = "Error al crear la informacion bancaria"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  async function update(id: number, input: Partial<BankInfoForm>) {
    loading.value = true
    error.value = null
    try {
      const record = await updateBankInfo(id, input)
      const idx = list.value.findIndex((b) => b.id === id)
      if (idx !== -1) {
        list.value[idx] = record
      }
      return true
    } catch (err) {
      error.value = "Error al actualizar la informacion bancaria"
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
      await deleteBankInfo(id)
      list.value = list.value.filter((b) => b.id !== id)
      return true
    } catch (err) {
      error.value = "Error al eliminar la informacion bancaria"
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
