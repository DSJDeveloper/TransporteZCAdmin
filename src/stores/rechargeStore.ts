import { defineStore } from "pinia"
import { ref } from "vue"
import {
  getRecharges,
  getRechargeStats,
  processRechargeStatus,
  type Recharge,
  type RechargeStats,
  type RechargeFilters,
} from "../services/rechargeService"

export const useRechargeStore = defineStore("recharge", () => {
  const list = ref<Recharge[]>([])
  const totalCount = ref(0)
  const loading = ref(false)
  const error = ref<string | null>(null)

  const sortField = ref("id")
  const sortAsc = ref(false)

  const stats = ref<RechargeStats>({ pending: 0, rejected: 0, approved: 0, total_amount: 0 })
  const statsLoading = ref(false)
  const statsError = ref<string | null>(null)

  async function fetchRecharges(page: number, perPage: number, filters?: RechargeFilters) {
    loading.value = true
    error.value = null
    try {
      const result = await getRecharges(page, perPage, filters, sortField.value, sortAsc.value)
      list.value = result.data
      totalCount.value = result.count
      return true
    } catch (err) {
      error.value = "Error al cargar las recargas"
      console.error(err)
      return false
    } finally {
      loading.value = false
    }
  }

  function setSort(field: string) {
    if (sortField.value === field) {
      sortAsc.value = !sortAsc.value
    } else {
      sortField.value = field
      sortAsc.value = false
    }
  }

  async function fetchStats() {
    statsLoading.value = true
    statsError.value = null
    try {
      stats.value = await getRechargeStats()
      return true
    } catch (err) {
      statsError.value = "Error al cargar estadísticas"
      console.error(err)
      return false
    } finally {
      statsLoading.value = false
    }
  }

  async function processRecharge(id: number, action: "approve" | "reject", approvedBy: string) {
    error.value = null
    try {
      await processRechargeStatus(id, action, approvedBy)
      const found = list.value.find((r) => r.id === id)
      if (found) {
        found.status = action === "approve" ? 1 : 2
      }
      await fetchStats()
      return true
    } catch (err) {
      error.value = "Error al procesar la recarga"
      console.error(err)
      return false
    }
  }

  function $reset() {
    list.value = []
    totalCount.value = 0
    loading.value = false
    error.value = null
    sortField.value = "id"
    sortAsc.value = false
    stats.value = { pending: 0, rejected: 0, approved: 0, total_amount: 0 }
    statsLoading.value = false
    statsError.value = null
  }

  return {
    list,
    totalCount,
    loading,
    error,
    sortField,
    sortAsc,
    stats,
    statsLoading,
    statsError,
    fetchRecharges,
    fetchStats,
    processRecharge,
    setSort,
    $reset,
  }
})
