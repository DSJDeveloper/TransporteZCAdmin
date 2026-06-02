import { defineStore } from "pinia"
import { ref } from "vue"
import companyService, { type InfoCompany } from "../services/companyService"

export const useCompanyStore = defineStore("company", () => {
  const company = ref<InfoCompany | null>(null)
  const loading = ref(false)
  const saving = ref(false)
  const error = ref<string | null>(null)
  const successMessage = ref<string | null>(null)

  async function fetchCompany() {
    loading.value = true
    error.value = null
    try {
      company.value = await companyService.getInfoCompany()
    } catch (err) {
      error.value = "Error al cargar la información de la empresa"
      console.error(err)
    } finally {
      loading.value = false
    }
  }

  async function saveCompany(payload: Partial<InfoCompany> & { id: number }) {
    saving.value = true
    error.value = null
    successMessage.value = null
    try {
      company.value = await companyService.updateCompany(payload)
      successMessage.value = "Empresa actualizada exitosamente"
    } catch (err) {
      error.value = "Error al guardar los datos"
      console.error(err)
    } finally {
      saving.value = false
    }
  }

  function clearMessages() {
    error.value = null
    successMessage.value = null
  }

  return {
    company,
    loading,
    saving,
    error,
    successMessage,
    fetchCompany,
    saveCompany,
    clearMessages,
  }
})
