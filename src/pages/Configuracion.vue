<script setup lang="ts">
import { ref, computed, onMounted, watch } from "vue"
import { useCompanyStore } from "../stores/companyStore"
import { useAuthStore } from "../stores/authStore"
import { useTicketStore } from "../stores/ticketStore"

const store = useCompanyStore()
const auth = useAuthStore()

const isAdmin = computed(() => auth.user?.role === "admin")
const ticketStore = useTicketStore()
const form = ref({
  name: "",
  rif: "",
  phone: "",
  ticket: 0,
  tasa: 0,
  account: "",
  rifAccount: "",
  phoneAccount: "",
})

onMounted(async () => {
  await store.fetchCompany()
  if (store.company) syncForm()
  await ticketStore.getTasa()
  form.value.tasa = ticketStore.tasa
})

watch(() => store.company, (val) => {
  if (val) syncForm()
})

function syncForm() {
  const c = store.company
  if (!c) return
  form.value.name = c.name ?? ""
  form.value.rif = c.rif ?? ""
  form.value.phone = c.phone ?? ""
  form.value.ticket = c.ticket ?? 0
  form.value.tasa = c.tasa ?? 0
  form.value.account = c.account ?? ""
  form.value.rifAccount = c.rifAccount ?? ""
  form.value.phoneAccount = c.phoneAccount ?? ""
}

function hasChanges(): boolean {
  const c = store.company
  if (!c) return true
  return (
    form.value.name !== (c.name ?? "") ||
    form.value.rif !== (c.rif ?? "") ||
    form.value.phone !== (c.phone ?? "") ||
    form.value.ticket !== (c.ticket ?? 0) ||
    form.value.tasa !== (c.tasa ?? 0) ||
    form.value.account !== (c.account ?? "") ||
    form.value.rifAccount !== (c.rifAccount ?? "") ||
    form.value.phoneAccount !== (c.phoneAccount ?? "")
  )
}

function discard() {
  if (store.company) syncForm()
  store.clearMessages()
}

async function save() {
  if (!store.company?.id) return
  store.clearMessages()
  await store.saveCompany({
    id: store.company.id,
    name: form.value.name,
    rif: form.value.rif || null,
    phone: form.value.phone || null,
    ticket: form.value.ticket,
    tasa: form.value.tasa,
    account: form.value.account || null,
    rifAccount: form.value.rifAccount || null,
    phoneAccount: form.value.phoneAccount || null,
  })
}

</script>

<template>
  <div class="p-margin-mobile md:p-margin-desktop min-h-screen">
    <!-- Breadcrumbs & Title -->
    <div class="mb-lg">
      <div class="flex items-center gap-xs text-label-md text-outline mb-xs">
        <span>Configuraciones</span>
        <span class="material-symbols-outlined text-[14px]">chevron_right</span>
        <span class="text-primary font-bold">Parámetros de la Empresa</span>
      </div>
      <h2 class="text-headline-lg text-on-surface font-bold">Configuración de Parámetros</h2>
      <p class="text-body-lg text-on-surface-variant">
        Gestione la información fiscal, operativa y de cobro de su plataforma logística.
      </p>
    </div>

    <!-- Success / Error messages -->
    <Transition name="fade">
      <div v-if="store.successMessage" class="mb-lg p-md rounded-lg bg-tertiary-container/20 border border-tertiary-container text-tertiary text-body-md flex items-center gap-sm">
        <span class="material-symbols-outlined">check_circle</span>
        <span>{{ store.successMessage }}</span>
      </div>
    </Transition>
    <Transition name="fade">
      <div v-if="store.error" class="mb-lg p-md rounded-lg bg-error-container/20 border border-error-container text-error text-body-md flex items-center gap-sm">
        <span class="material-symbols-outlined">error</span>
        <span>{{ store.error }}</span>
      </div>
    </Transition>

    <!-- Loading skeleton -->
    <div v-if="store.loading" class="space-y-lg">
      <div v-for="n in 3" :key="n" class="bg-surface-container-lowest border border-outline-variant rounded-xl p-lg animate-pulse">
        <div class="h-6 w-48 bg-surface-container-high rounded mb-lg"></div>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-md">
          <div v-for="m in 4" :key="m" class="space-y-base">
            <div class="h-4 w-24 bg-surface-container-high rounded"></div>
            <div class="h-10 w-full bg-surface-container-high rounded-lg"></div>
          </div>
        </div>
      </div>
    </div>

    <template v-else>
      <!-- Basic Info Card -->
      <section class="bg-surface-container-lowest border border-outline-variant rounded-xl p-lg form-card-shadow mb-lg">
        <div class="flex items-center gap-sm mb-lg border-b border-surface-container pb-md">
          <span class="material-symbols-outlined text-primary" style="font-variation-settings: 'FILL' 1;">business_center</span>
          <h3 class="text-headline-sm font-semibold">Información de la Empresa</h3>
        </div>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-md">
          <div class="space-y-base">
            <label class="text-label-md font-semibold text-on-surface-variant px-1">Nombre de la Empresa</label>
            <input
              v-model="form.name"
              class="w-full border-outline-variant focus:border-primary focus:ring-1 focus:ring-primary rounded-lg text-body-md py-3 px-3 bg-surface-container-low transition-all disabled:opacity-60 disabled:cursor-not-allowed"
              type="text"
              placeholder="Nombre de la empresa"
              :disabled="!isAdmin"
            />
          </div>
          <div class="space-y-base">
            <label class="text-label-md font-semibold text-on-surface-variant px-1">RIF Empresa</label>
            <input
              v-model="form.rif"
              class="w-full border-outline-variant focus:border-primary focus:ring-1 focus:ring-primary rounded-lg text-body-md py-3 px-3 bg-surface-container-low transition-all disabled:opacity-60 disabled:cursor-not-allowed"
              type="text"
              placeholder="J-XXXXXXXX-X"
              :disabled="!isAdmin"
            />
          </div>
          <div class="space-y-base">
            <label class="text-label-md font-semibold text-on-surface-variant px-1">Teléfono Empresa</label>
            <div class="relative">
              <span class="material-symbols-outlined absolute left-3 top-1/2 -translate-y-1/2 text-outline text-[20px]">call</span>
              <input
                v-model="form.phone"
                class="w-full border-outline-variant focus:border-primary focus:ring-1 focus:ring-primary rounded-lg text-body-md py-3 pl-10 bg-surface-container-low transition-all disabled:opacity-60 disabled:cursor-not-allowed"
                type="text"
                placeholder="0414-XXXXXXX"
                :disabled="!isAdmin"
              />
            </div>
          </div>
        </div>
      </section>

      <!-- Financial Parameters -->
      <section class="bg-surface-container-lowest border border-outline-variant rounded-xl p-lg form-card-shadow mb-lg">
        <div class="flex items-center gap-sm mb-lg border-b border-surface-container pb-md">
          <span class="material-symbols-outlined text-tertiary" style="font-variation-settings: 'FILL' 1;">payments</span>
          <h3 class="text-headline-sm font-semibold">Parámetros Financieros</h3>
        </div>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-md">
          <div class="space-y-base">
            <label class="text-label-md font-semibold text-on-surface-variant px-1">Precio del Ticket (USD)</label>
            <div class="relative">
              <span class="absolute left-3 top-1/2 -translate-y-1/2 text-outline font-bold">$</span>
              <input
                v-model.number="form.ticket"
                class="w-full border-outline-variant focus:border-primary focus:ring-1 focus:ring-primary rounded-lg text-body-md py-3 pl-8 pr-3 bg-surface-container-low transition-all disabled:opacity-60 disabled:cursor-not-allowed"
                step="0.01"
                type="number"
                :disabled="!isAdmin"
              />
            </div>
          </div>
          <div class="space-y-base">
            <label class="text-label-md font-semibold text-on-surface-variant px-1">Tasa de Cambio (VES) <span class="text-outline font-normal">— Referencial (BCV)</span></label>
            <div class="relative">
              <span class="absolute left-3 top-1/2 -translate-y-1/2 text-outline font-bold">Bs</span>
              <input
                v-model.number="form.tasa"
                class="w-full border-outline-variant focus:border-primary focus:ring-1 focus:ring-primary rounded-lg text-body-md py-3 pl-10 pr-3 bg-surface-container-low transition-all disabled:opacity-60 disabled:cursor-not-allowed"
                step="0.01"
                type="number"
                disabled
              />
              <div class="absolute right-3 top-1/2 -translate-y-1/2 flex items-center gap-1">
                <span v-if="ticketStore.loading.tasa" class="animate-spin material-symbols-outlined text-[16px] text-outline">sync</span>
                <span v-else class="material-symbols-outlined text-[16px] text-tertiary" title="Valor obtenido del Banco Central de Venezuela">check_circle</span>
              </div>
            </div>
          </div>
        </div>
      </section>

      <!-- Banking Info Card -->
      <!-- <section class="bg-surface-container-lowest border border-outline-variant rounded-xl p-lg form-card-shadow mb-lg">
        <div class="flex items-center gap-sm mb-lg border-b border-surface-container pb-md">
          <span class="material-symbols-outlined text-secondary" style="font-variation-settings: 'FILL' 1;">account_balance</span>
          <h3 class="text-headline-sm font-semibold">Información Bancaria</h3>
        </div>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-md">
          <div class="space-y-base">
            <label class="text-label-md font-semibold text-on-surface-variant px-1">Número de Cuenta</label>
            <input
              v-model="form.account"
              class="w-full border-outline-variant focus:border-primary focus:ring-1 focus:ring-primary rounded-lg text-body-md py-3 px-3 bg-surface-container-low transition-all disabled:opacity-60 disabled:cursor-not-allowed"
              type="text"
              placeholder="Número de cuenta"
              :disabled="!isAdmin"
            />
          </div>
          <div class="space-y-base">
            <label class="text-label-md font-semibold text-on-surface-variant px-1">RIF / Cédula</label>
            <input
              v-model="form.rifAccount"
              class="w-full border-outline-variant focus:border-primary focus:ring-1 focus:ring-primary rounded-lg text-body-md py-3 px-3 bg-surface-container-low transition-all disabled:opacity-60 disabled:cursor-not-allowed"
              type="text"
              placeholder="V-XXXXXXXX"
              :disabled="!isAdmin"
            />
          </div>
          <div class="space-y-base">
            <label class="text-label-md font-semibold text-on-surface-variant px-1">Teléfono Afiliado</label>
            <input
              v-model="form.phoneAccount"
              class="w-full border-outline-variant focus:border-primary focus:ring-1 focus:ring-primary rounded-lg text-body-md py-3 px-3 bg-surface-container-low transition-all disabled:opacity-60 disabled:cursor-not-allowed"
              type="text"
              placeholder="0412-XXXXXXX"
              :disabled="!isAdmin"
            />
          </div>
        </div>
      </section> -->

      <!-- Actions -->
      <div v-if="isAdmin" class="flex items-center justify-end gap-md pt-md">
        <button
          class="px-lg py-3 rounded-lg border border-outline text-on-surface hover:bg-surface-container transition-all font-bold text-body-md"
          :disabled="!hasChanges() || store.saving"
          @click="discard"
        >
          Descartar Cambios
        </button>
        <button
          class="px-xl py-3 rounded-lg bg-primary text-on-primary hover:bg-primary-container shadow-md transition-all font-bold text-body-md flex items-center gap-sm disabled:opacity-50 disabled:pointer-events-none"
          :disabled="!hasChanges() || store.saving"
          @click="save"
        >
          <span v-if="store.saving" class="material-symbols-outlined text-[20px] animate-spin">sync</span>
          <span v-else class="material-symbols-outlined text-[20px]">save</span>
          {{ store.saving ? 'Guardando...' : 'Actualizar Empresa' }}
        </button>
      </div>
      <div v-else class="flex items-center justify-center pt-md mb-lg">
        <p class="text-body-md text-outline flex items-center gap-sm">
          <span class="material-symbols-outlined">lock</span>
          Solo los administradores pueden modificar estos datos
        </p>
      </div>

    </template>
  </div>
</template>

<style scoped>
.form-card-shadow {
  box-shadow: 0px 4px 12px rgba(0, 0, 0, 0.05);
}
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.2s ease;
}
.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}
</style>
