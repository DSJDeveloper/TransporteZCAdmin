<script setup lang="ts">
import { ref, computed, reactive, watch, onMounted } from "vue"
import { useClientStore } from "../stores/clientStore"
import type { Client, ClientForm } from "../services/clientService"
import ticketsService from "../services/ticketsService"
import type { Movimiento } from "../services/ticketsService"
import { formatDateTime, formatCurrency } from "../utils/formatters"

const store = useClientStore()

const selectedClient = ref<Client | null>(null)
const movements = ref<Movimiento[]>([])
const movementsLoading = ref(false)
const movementsError = ref("")

const search = ref("")
const page = ref(1)
const perPage = ref(10)
const sortField = ref("id")
const sortAsc = ref(true)

const dialogOpen = ref(false)
const editing = ref<Client | null>(null)
const saving = ref(false)
const form = ref<ClientForm>({ name: "", documentID: "", email: "", phone: "", carrer: "", creditLimit: "", status: "0" })
const errors = reactive<Record<string, string>>({})

const movementsLimit = 20

async function openMovements(c: Client) {
  selectedClient.value = c
  movements.value = []
  movementsError.value = ""
  movementsLoading.value = true
  try {
    const result = await ticketsService.getMovimientosUnificado(c.id)
    movements.value = result.history.slice(0, movementsLimit)
  } catch (err) {
    movementsError.value = "Error al cargar los movimientos"
    console.error(err)
  } finally {
    movementsLoading.value = false
  }
}

function closeMovements() {
  selectedClient.value = null
  movements.value = []
}

function movementStatusLabel(status: number): string {
  if (status === 0 || status === 1) return "Activo"
  if (status === 2) return "Pendiente"
  if (status === 3) return "Rechazado"
  return "Desconocido"
}

function movementStatusClass(status: number): string {
  if (status === 0 || status === 1) return "bg-tertiary-fixed text-on-tertiary-fixed"
  if (status === 2) return "bg-primary-container/30 text-primary"
  return "bg-error-container/30 text-error"
}

const deleting = ref<Client | null>(null)
const deletingConfirm = ref(false)

const filtered = computed(() => {
  const q = search.value.toLowerCase().trim()
  if (!q) return store.list
  return store.list.filter(
    (c) =>
      c.name.toLowerCase().includes(q) ||
      c.phone.toLowerCase().includes(q) ||
      c.email.toLowerCase().includes(q) ||
      c.documentID.toLowerCase().includes(q),
  )
})

const totalPages = computed(() => Math.max(1, Math.ceil(filtered.value.length / perPage.value)))

function compare(a: Client, b: Client, field: string): number {
  const va = (a as any)[field]
  const vb = (b as any)[field]
  if (typeof va === "number" && typeof vb === "number") return va - vb
  return String(va ?? "").localeCompare(String(vb ?? ""), "es")
}

const sorted = computed(() => {
  const list = filtered.value
  if (!sortField.value) return list
  return [...list].sort((a, b) => {
    const cmp = compare(a, b, sortField.value)
    return sortAsc.value ? cmp : -cmp
  })
})

const paginated = computed(() => {
  const start = (page.value - 1) * perPage.value
  return sorted.value.slice(start, start + perPage.value)
})

const pageRange = computed(() => {
  const total = totalPages.value
  const current = page.value
  const pages: (number | string)[] = []
  if (total <= 7) {
    for (let i = 1; i <= total; i++) pages.push(i)
  } else {
    pages.push(1)
    if (current > 3) pages.push("...")
    const start = Math.max(2, current - 1)
    const end = Math.min(total - 1, current + 1)
    for (let i = start; i <= end; i++) pages.push(i)
    if (current < total - 2) pages.push("...")
    pages.push(total)
  }
  return pages
})

const fromRecord = computed(() => (page.value - 1) * perPage.value + 1)
const toRecord = computed(() => Math.min(page.value * perPage.value, filtered.value.length))

function goToPage(p: number | string) {
  if (typeof p !== "number") return
  if (p < 1 || p > totalPages.value) return
  page.value = p
}

watch(search, () => { page.value = 1 })
watch(perPage, () => { page.value = 1 })
watch([sortField, sortAsc], () => { page.value = 1 })

const columns = [
  { key: "id", label: "#" },
  { key: "name", label: "CLIENTE" },
  { key: "phone", label: "TELÉFONO" },
  { key: "email", label: "CORREO" },
  { key: "balance", label: "SALDO" },
]

function sortIcon(key: string): string {
  if (sortField.value !== key) return "unfold_more"
  return sortAsc.value ? "arrow_upward" : "arrow_downward"
}

function toggleSort(key: string) {
  if (sortField.value === key) {
    sortAsc.value = !sortAsc.value
  } else {
    sortField.value = key
    sortAsc.value = true
  }
}

function initials(name: string): string {
  return name
    .split(" ")
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w.charAt(0).toUpperCase())
    .join("")
}

function validate(): boolean {
  const e: Record<string, string> = {}
  if (!form.value.name.trim()) e.name = "El nombre es obligatorio"
  if (!form.value.documentID.trim()) e.documentID = "La cédula es obligatoria"
  if (!form.value.email.trim()) e.email = "El correo es obligatorio"
  if (!form.value.phone.trim()) e.phone = "El teléfono es obligatorio"
  if (!form.value.carrer.trim()) e.carrer = "La carrera es obligatoria"
  if (!form.value.creditLimit.trim()) e.creditLimit = "El límite de crédito es obligatorio"
  Object.assign(errors, e)
  return Object.keys(errors).length === 0
}

function clearErrors() {
  for (const key of Object.keys(errors)) {
    delete errors[key]
  }
}

function openCreate() {
  editing.value = null
  form.value = { name: "", documentID: "", email: "", phone: "", carrer: "", creditLimit: "", status: "0" }
  clearErrors()
  dialogOpen.value = true
}

function openEdit(c: Client) {
  editing.value = c
  form.value = {
    name: c.name,
    documentID: c.documentID,
    email: c.email,
    phone: c.phone,
    carrer: c.carrer,
    creditLimit: c.creditLimit,
    status: c.status,
  }
  clearErrors()
  dialogOpen.value = true
}

async function save() {
  clearErrors()
  if (!validate()) return
  saving.value = true
  try {
    const ok = editing.value
      ? await store.update(editing.value.id, form.value)
      : await store.create(form.value)
    if (ok) {
      dialogOpen.value = false
    }
  } finally {
    saving.value = false
  }
}

function confirmDelete(c: Client) {
  deleting.value = c
  deletingConfirm.value = true
}

async function doDelete() {
  if (!deleting.value) return
  const ok = await store.remove(deleting.value.id)
  if (ok) {
    deletingConfirm.value = false
    deleting.value = null
  }
}

onMounted(() => store.fetchAll())
</script>

<template>
  <div class="p-margin-mobile md:p-margin-desktop min-h-screen">
    <!-- Header -->
    <div class="flex flex-col sm:flex-row sm:justify-between sm:items-end gap-md mb-lg">
      <div>
        <h2 class="font-headline-lg text-headline-lg text-on-surface">Lista de Clientes</h2>
        <nav class="flex items-center text-label-md text-on-surface-variant mt-base">
          <span>Panel Principal</span>
          <span class="material-symbols-outlined text-[14px] mx-xs">chevron_right</span>
          <span class="text-primary font-bold">Clientes</span>
        </nav>
      </div>
      <button
        class="bg-primary hover:bg-surface-tint text-on-primary px-lg py-sm rounded-xl font-headline-sm text-headline-sm flex items-center justify-center gap-sm transition-all shadow-md active:scale-95 w-full sm:w-auto"
        @click="openCreate"
      >
        <span class="material-symbols-outlined">add</span>
        <span>Nuevo Cliente</span>
      </button>
    </div>

    <!-- Table section -->
    <section class="bg-surface-container-lowest rounded-xl border border-outline-variant shadow-sm overflow-hidden">
      <div class="p-md md:p-lg border-b border-outline-variant flex flex-col md:flex-row md:items-center md:justify-between gap-md bg-surface-container-low/30">
        <h4 class="font-headline-sm text-headline-sm text-on-surface">Clientes Registrados</h4>
        <div class="flex items-center gap-md w-full md:w-auto">
          <div class="flex items-center gap-xs text-body-md text-on-surface-variant whitespace-nowrap">
            <span class="hidden md:inline">Mostrar</span>
            <select
              v-model.number="perPage"
              class="bg-surface-container-lowest border border-outline-variant rounded-lg text-body-md py-1 pl-2 pr-1 focus:ring-primary focus:border-primary outline-none"
            >
                  <option :value="10">10</option>
            <option :value="25">25</option>
            <option :value="50">50</option>
            <option :value="100">100</option>
            <option :value="150">150</option>
            <option :value="500">500</option>
            </select>
            <span class="hidden md:inline">registros</span>
          </div>
          <div class="relative flex-1 md:flex-none">
            <span class="material-symbols-outlined absolute left-3 top-1/2 -translate-y-1/2 text-outline text-[18px]">search</span>
            <input
              v-model="search"
              class="w-full md:w-56 pl-9 pr-3 py-1.5 bg-surface-container-low border border-outline-variant rounded-lg text-body-md focus:border-primary outline-none transition-all"
              placeholder="Buscar clientes..."
              type="text"
            />
          </div>
        </div>
      </div>

      <!-- Loading state -->
      <div v-if="store.loading" class="p-xl text-center text-on-surface-variant">
        <span class="animate-spin material-symbols-outlined inline-block">sync</span>
        <p class="mt-2">Cargando clientes...</p>
      </div>

      <!-- Empty state -->
      <div v-else-if="!filtered.length" class="p-xl text-center text-on-surface-variant">
        <span class="material-symbols-outlined text-[48px] text-outline">group</span>
        <p class="mt-2">No se encontraron clientes</p>
      </div>

      <!-- Data: table (md+) or cards (mobile) -->
      <template v-else>
        <!-- Desktop table -->
        <div class="hidden md:block overflow-x-auto">
          <table class="w-full text-left font-body-md text-body-md border-collapse">
            <thead class="bg-surface-container-high/20 border-b border-outline-variant">
              <tr>
                <th v-for="col in columns" :key="col.key"
                  class="px-lg py-md font-bold text-on-surface-variant uppercase text-[11px] tracking-widest cursor-pointer select-none hover:text-on-surface transition-colors"
                  :class="col.key === 'balance' ? 'text-right' : ''"
                  @click="toggleSort(col.key)"
                >
                  <span class="inline-flex items-center gap-1">
                    {{ col.label }}
                    <span class="material-symbols-outlined text-[14px] leading-none"
                      :class="sortField === col.key ? 'text-primary' : 'text-outline/40'">{{ sortIcon(col.key) }}</span>
                  </span>
                </th>
                <th class="px-lg py-md font-bold text-on-surface-variant uppercase text-[11px] tracking-widest text-center">ACCIONES</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-outline-variant">
              <tr v-for="c in paginated" :key="c.id" class="hover:bg-primary-container/5 transition-colors group">
                <td class="px-lg py-md text-label-md font-bold text-outline">{{ c.id }}</td>
                <td class="px-lg py-md">
                  <div class="flex items-center gap-md">
                    <div
                      class="w-8 h-8 rounded-full flex items-center justify-center font-bold text-xs shrink-0"
                      :class="c.status === '0' ? 'bg-primary-container/20 text-primary' : 'bg-outline-variant text-outline'"
                    >
                      {{ initials(c.name) }}
                    </div>
                    <div class="flex items-center gap-xs">
                      <span class="font-body-md font-semibold text-on-surface">{{ c.name }}</span>
                      <span
                        v-if="c.status !== '0'"
                        class="bg-outline-variant text-on-surface-variant text-[10px] px-xs py-[2px] rounded-full font-bold"
                      >INACTIVO</span>
                    </div>
                  </div>
                </td>
                <td class="px-lg py-md text-body-md text-on-surface-variant">{{ c.phone }}</td>
                <td class="px-lg py-md text-body-md text-on-surface-variant">{{ c.email }}</td>
                <td class="px-lg py-md text-right font-bold" :class="c.balance < 0 ? 'text-error' : 'text-primary'">
                  {{ c.balance.toFixed(2) }} USD
                </td>
                <td class="px-lg py-md text-center">
                    <div class="flex items-center justify-center gap-xs opacity-0 group-hover:opacity-100 transition-opacity">
                      <button class="p-xs hover:bg-secondary/10 rounded-lg text-secondary transition-colors" title="Ver movimientos" @click="openMovements(c)">
                        <span class="material-symbols-outlined text-[20px]">receipt_long</span>
                      </button>
                      <button class="p-xs hover:bg-primary/10 rounded-lg text-primary transition-colors" title="Editar" @click="openEdit(c)">
                        <span class="material-symbols-outlined text-[20px]">edit</span>
                      </button>
                      <button class="p-xs hover:bg-error/10 rounded-lg text-error transition-colors" title="Eliminar" @click="confirmDelete(c)">
                        <span class="material-symbols-outlined text-[20px]">delete</span>
                      </button>
                    </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <!-- Mobile cards -->
        <div class="md:hidden divide-y divide-outline-variant">
          <div v-for="c in paginated" :key="c.id" class="p-md space-y-sm">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-md">
                <div
                  class="w-8 h-8 rounded-full flex items-center justify-center font-bold text-xs shrink-0"
                  :class="c.status === '0' ? 'bg-primary-container/20 text-primary' : 'bg-outline-variant text-outline'"
                >
                  {{ initials(c.name) }}
                </div>
                <div>
                  <span class="font-bold text-on-surface">{{ c.name }}</span>
                  <span
                    v-if="c.status !== '0'"
                    class="ml-1 bg-outline-variant text-on-surface-variant text-[10px] px-1 py-[2px] rounded-full font-bold"
                  >INACTIVO</span>
                </div>
              </div>
            </div>
            <div class="grid grid-cols-2 gap-2 text-body-md text-on-surface-variant">
              <div class="flex items-center gap-1">
                <span class="material-symbols-outlined text-[16px] text-outline">phone</span>
                <span>{{ c.phone }}</span>
              </div>
              <div class="flex items-center gap-1 justify-end">
                <span class="material-symbols-outlined text-[16px] text-outline">mail</span>
                <span class="truncate">{{ c.email }}</span>
              </div>
            </div>
            <div class="flex items-center justify-between">
              <span class="font-bold" :class="c.balance < 0 ? 'text-error' : 'text-primary'">
                {{ c.balance.toFixed(2) }} USD
              </span>
              <div class="flex gap-xs">
                <button
                  class="flex-1 flex items-center justify-center gap-1 py-2 px-3 rounded-lg border border-outline-variant text-secondary font-bold text-[13px] hover:bg-secondary/10 transition-colors"
                  @click="openMovements(c)"
                >
                  <span class="material-symbols-outlined text-[18px]">receipt_long</span>
                  Movimientos
                </button>
                <button
                  class="flex-1 flex items-center justify-center gap-1 py-2 px-3 rounded-lg border border-outline-variant text-primary font-bold text-[13px] hover:bg-primary-container/10 transition-colors"
                  @click="openEdit(c)"
                >
                  <span class="material-symbols-outlined text-[18px]">edit</span>
                  Editar
                </button>
                <button
                  class="flex-1 flex items-center justify-center gap-1 py-2 px-3 rounded-lg border border-outline-variant text-error font-bold text-[13px] hover:bg-error-container/10 transition-colors"
                  @click="confirmDelete(c)"
                >
                  <span class="material-symbols-outlined text-[18px]">delete</span>
                  Eliminar
                </button>
              </div>
            </div>
          </div>
        </div>
      </template>

      <!-- Pagination -->
      <div class="p-md md:p-lg border-t border-outline-variant flex flex-col md:flex-row items-center justify-between gap-md bg-surface-container-low/20">
        <p class="font-body-md text-body-md text-on-surface-variant text-center md:text-left">
          Mostrando <span class="font-bold text-on-surface">{{ fromRecord }}-{{ toRecord }}</span> de <span class="font-bold text-on-surface">{{ filtered.length }}</span> registros
        </p>
        <div class="flex items-center gap-xs">
          <button
            class="p-xs rounded-lg hover:bg-surface-container-high text-secondary disabled:opacity-30 transition-colors"
            :disabled="page <= 1"
            @click="goToPage(page - 1)"
          >
            <span class="material-symbols-outlined">chevron_left</span>
          </button>
          <div class="flex gap-xs">
            <template v-for="p in pageRange" :key="p">
              <button
                v-if="p === '...'"
                class="px-1 self-center text-outline text-label-md"
                disabled
              >...</button>
              <button
                v-else
                class="w-8 h-8 rounded-lg text-label-md font-bold transition-colors"
                :class="p === page ? 'bg-primary text-on-primary' : 'hover:bg-surface-container-high text-on-surface-variant'"
                @click="goToPage(p)"
              >{{ p }}</button>
            </template>
          </div>
          <button
            class="p-xs rounded-lg hover:bg-surface-container-high text-secondary disabled:opacity-30 transition-colors"
            :disabled="page >= totalPages"
            @click="goToPage(page + 1)"
          >
            <span class="material-symbols-outlined">chevron_right</span>
          </button>
        </div>
      </div>
    </section>

    <!-- Movements Dialog -->
    <Teleport to="body">
      <div v-if="selectedClient" class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="absolute inset-0 bg-black/30 backdrop-blur-sm" @click="closeMovements"></div>
        <div class="relative bg-surface-container-lowest rounded-xl shadow-2xl border border-outline-variant w-full max-w-3xl mx-auto p-md md:p-xl max-h-[90vh] flex flex-col">
          <!-- Header -->
          <div class="flex items-center justify-between mb-lg shrink-0">
            <div>
              <h3 class="font-headline-sm text-headline-sm text-on-surface">Movimientos</h3>
              <p class="text-body-md text-on-surface-variant mt-xs">
                Últimos <strong>{{ movementsLimit }}</strong> movimientos de <strong>{{ selectedClient.name }}</strong>
              </p>
            </div>
            <button class="text-outline hover:text-on-surface transition-colors" @click="closeMovements">
              <span class="material-symbols-outlined">close</span>
            </button>
          </div>

          <!-- Loading -->
          <div v-if="movementsLoading" class="flex-1 flex items-center justify-center text-on-surface-variant">
            <span class="animate-spin material-symbols-outlined inline-block">sync</span>
            <p class="ml-2">Cargando movimientos...</p>
          </div>

          <!-- Error -->
          <div v-else-if="movementsError" class="flex-1 flex items-center justify-center text-error">
            <span class="material-symbols-outlined">error</span>
            <p class="ml-2">{{ movementsError }}</p>
          </div>

          <!-- Empty -->
          <div v-else-if="!movements.length" class="flex-1 flex items-center justify-center text-on-surface-variant">
            <span class="material-symbols-outlined text-[48px] text-outline">receipt_long</span>
            <p class="ml-2">Sin movimientos registrados</p>
          </div>

          <!-- Movements table -->
          <div v-else class="flex-1 overflow-y-auto custom-scrollbar -mx-md md:-mx-xl">
            <table class="w-full text-left font-body-md text-body-md border-collapse">
              <thead class="bg-surface-container-high/20 sticky top-0 z-10">
                <tr>
                  <th class="px-lg py-md font-bold text-on-surface-variant uppercase text-[11px] tracking-widest">FECHA</th>
                  <th class="px-lg py-md font-bold text-on-surface-variant uppercase text-[11px] tracking-widest">TIPO</th>
                  <th class="px-lg py-md font-bold text-on-surface-variant uppercase text-[11px] tracking-widest text-right">MONTO</th>
                  <th class="px-lg py-md font-bold text-on-surface-variant uppercase text-[11px] tracking-widest text-right">SALDO</th>
                  <th class="px-lg py-md font-bold text-on-surface-variant uppercase text-[11px] tracking-widest">ESTADO</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-outline-variant">
                <tr v-for="m in movements" :key="m.id + m.type" class="hover:bg-primary-container/5 transition-colors">
                  <td class="px-lg py-md text-on-surface whitespace-nowrap">{{ formatDateTime(m.created_at || m.date) }}</td>
                  <td class="px-lg py-md">
                    <span class="inline-flex items-center gap-1 font-bold" :class="m.isRecharge ? 'text-primary' : 'text-on-surface'">
                      <span class="material-symbols-outlined text-[16px]">{{ m.isRecharge ? 'add_circle' : 'remove_circle' }}</span>
                      {{ m.isRecharge ? "Recarga" : "Transacción" }}
                    </span>
                  </td>
                  <td class="px-lg py-md text-right font-bold" :class="m.isRecharge ? 'text-primary' : 'text-error'">
                    {{ m.isRecharge ? "+" : "−" }}{{ formatCurrency(Math.abs(m.amount)) }}
                  </td>
                  <td class="px-lg py-md text-right text-on-surface font-bold">
                    {{ m.newBalanceClient != null ? formatCurrency(m.newBalanceClient) : "—" }}
                  </td>
                  <td class="px-lg py-md">
                    <span class="px-sm py-1 rounded-full text-[11px] font-bold whitespace-nowrap" :class="movementStatusClass(m.status)">
                      {{ movementStatusLabel(m.status) }}
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <!-- Footer -->
          <div class="flex items-center justify-end pt-md mt-md border-t border-outline-variant shrink-0">
            <button
              class="h-11 px-lg rounded-xl bg-primary text-on-primary font-bold hover:shadow-lg transition-all"
              @click="closeMovements"
            >Cerrar</button>
          </div>
        </div>
      </div>
    </Teleport>

    <!-- Create/Edit Dialog -->
    <Teleport to="body">
      <div v-if="dialogOpen" class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="absolute inset-0 bg-black/30 backdrop-blur-sm" @click="dialogOpen = false"></div>
        <div class="relative bg-surface-container-lowest rounded-xl shadow-2xl border border-outline-variant w-full max-w-lg mx-auto p-md md:p-xl max-h-[90vh] overflow-y-auto">
          <div class="flex items-center justify-between mb-lg">
            <h3 class="font-headline-sm text-headline-sm text-on-surface">
              {{ editing ? "Editar Cliente" : "Nuevo Cliente" }}
            </h3>
            <button class="text-outline hover:text-on-surface transition-colors" @click="dialogOpen = false">
              <span class="material-symbols-outlined">close</span>
            </button>
          </div>
          <form @submit.prevent="save" class="space-y-lg">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-lg">
              <div class="space-y-base md:col-span-2">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Nombre</label>
                <input
                  v-model="form.name"
                  :class="[
                    'w-full h-11 px-md bg-surface-container-lowest border rounded-xl transition-all font-body-md text-body-md outline-none',
                    errors.name
                      ? 'border-error focus:ring-2 focus:ring-error focus:border-error'
                      : 'border-outline-variant focus:ring-2 focus:ring-primary focus:border-primary'
                  ]"
                  placeholder="Nombre completo"
                  @input="errors.name && delete errors.name"
                />
                <p v-if="errors.name" class="text-error text-[12px] font-bold">{{ errors.name }}</p>
              </div>
              <div class="space-y-base">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Cédula</label>
                <input
                  v-model="form.documentID"
                  :class="[
                    'w-full h-11 px-md bg-surface-container-lowest border rounded-xl transition-all font-body-md text-body-md outline-none',
                    errors.documentID
                      ? 'border-error focus:ring-2 focus:ring-error focus:border-error'
                      : 'border-outline-variant focus:ring-2 focus:ring-primary focus:border-primary'
                  ]"
                  placeholder="Ej. V-12345678"
                  @input="errors.documentID && delete errors.documentID"
                />
                <p v-if="errors.documentID" class="text-error text-[12px] font-bold">{{ errors.documentID }}</p>
              </div>
              <div class="space-y-base">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Correo</label>
                <input
                  v-model="form.email"
                  :class="[
                    'w-full h-11 px-md bg-surface-container-lowest border rounded-xl transition-all font-body-md text-body-md outline-none',
                    errors.email
                      ? 'border-error focus:ring-2 focus:ring-error focus:border-error'
                      : 'border-outline-variant focus:ring-2 focus:ring-primary focus:border-primary'
                  ]"
                  placeholder="correo@ejemplo.com"
                  type="email"
                  @input="errors.email && delete errors.email"
                />
                <p v-if="errors.email" class="text-error text-[12px] font-bold">{{ errors.email }}</p>
              </div>
              <div class="space-y-base">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Teléfono</label>
                <input
                  v-model="form.phone"
                  :class="[
                    'w-full h-11 px-md bg-surface-container-lowest border rounded-xl transition-all font-body-md text-body-md outline-none',
                    errors.phone
                      ? 'border-error focus:ring-2 focus:ring-error focus:border-error'
                      : 'border-outline-variant focus:ring-2 focus:ring-primary focus:border-primary'
                  ]"
                  placeholder="Ej. 0412-1234567"
                  @input="errors.phone && delete errors.phone"
                />
                <p v-if="errors.phone" class="text-error text-[12px] font-bold">{{ errors.phone }}</p>
              </div>
              <div class="space-y-base">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Carrera</label>
                <input
                  v-model="form.carrer"
                  :class="[
                    'w-full h-11 px-md bg-surface-container-lowest border rounded-xl transition-all font-body-md text-body-md outline-none',
                    errors.carrer
                      ? 'border-error focus:ring-2 focus:ring-error focus:border-error'
                      : 'border-outline-variant focus:ring-2 focus:ring-primary focus:border-primary'
                  ]"
                  placeholder="Carrera universitaria"
                  @input="errors.carrer && delete errors.carrer"
                />
                <p v-if="errors.carrer" class="text-error text-[12px] font-bold">{{ errors.carrer }}</p>
              </div>
              <div class="space-y-base">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Límite de Crédito</label>
                <input
                  v-model="form.creditLimit"
                  :class="[
                    'w-full h-11 px-md bg-surface-container-lowest border rounded-xl transition-all font-body-md text-body-md outline-none',
                    errors.creditLimit
                      ? 'border-error focus:ring-2 focus:ring-error focus:border-error'
                      : 'border-outline-variant focus:ring-2 focus:ring-primary focus:border-primary'
                  ]"
                  placeholder="Ej. 100.00"
                  @input="errors.creditLimit && delete errors.creditLimit"
                />
                <p v-if="errors.creditLimit" class="text-error text-[12px] font-bold">{{ errors.creditLimit }}</p>
              </div>
              <div class="space-y-base md:col-span-2">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Estado</label>
                <select
                  v-model="form.status"
                  class="w-full h-11 px-md bg-surface-container-lowest border border-outline-variant rounded-xl focus:ring-2 focus:ring-primary focus:border-primary transition-all font-body-md text-body-md text-on-surface"
                >
                  <option value="0">Activo</option>
                  <option value="1">Inactivo</option>
                </select>
              </div>
            </div>
            <div class="flex flex-col-reverse sm:flex-row justify-end gap-md pt-md border-t border-outline-variant">
              <button
                type="button"
                class="h-11 px-lg rounded-xl border border-outline-variant text-on-surface-variant font-bold hover:bg-surface-container transition-all"
                @click="dialogOpen = false"
              >Cancelar</button>
              <button
                type="submit"
                :disabled="saving"
                class="h-11 px-lg rounded-xl bg-primary text-on-primary font-bold hover:shadow-lg active:scale-[0.98] transition-all disabled:opacity-50 flex items-center justify-center gap-xs"
              >
                <template v-if="saving">
                  <span class="animate-spin material-symbols-outlined text-[18px]">sync</span>
                  Guardando...
                </template>
                <template v-else>
                  {{ editing ? "Actualizar" : "Crear" }}
                </template>
              </button>
            </div>
          </form>
        </div>
      </div>
    </Teleport>

    <!-- Delete Confirm Dialog -->
    <Teleport to="body">
      <div v-if="deletingConfirm" class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="absolute inset-0 bg-black/30 backdrop-blur-sm" @click="deletingConfirm = false"></div>
        <div class="relative bg-surface-container-lowest rounded-xl shadow-2xl border border-outline-variant w-full max-w-sm mx-auto p-md md:p-xl">
          <div class="flex items-start gap-md mb-lg">
            <div class="w-12 h-12 rounded-full bg-error-container/30 flex items-center justify-center shrink-0">
              <span class="material-symbols-outlined text-error text-[28px]">warning</span>
            </div>
            <div>
              <h3 class="font-headline-sm text-headline-sm text-on-surface">Eliminar Cliente</h3>
              <p class="text-body-md text-on-surface-variant mt-1">¿Estás seguro de eliminar <strong>{{ deleting?.name }}</strong>?</p>
              <p class="text-body-md text-on-surface-variant">Esta acción no se puede deshacer.</p>
            </div>
          </div>
          <div class="flex flex-col-reverse sm:flex-row justify-end gap-md">
            <button
              class="h-11 px-lg rounded-xl border border-outline-variant text-on-surface-variant font-bold hover:bg-surface-container transition-all"
              @click="deletingConfirm = false"
            >Cancelar</button>
            <button
              class="h-11 px-lg rounded-xl bg-error text-on-error font-bold hover:shadow-lg active:scale-[0.98] transition-all flex items-center justify-center gap-xs"
              @click="doDelete"
            >Eliminar</button>
          </div>
        </div>
      </div>
    </Teleport>
  </div>
</template>

<style scoped>
.custom-scrollbar::-webkit-scrollbar {
  width: 4px;
}
.custom-scrollbar::-webkit-scrollbar-track {
  background: transparent;
}
.custom-scrollbar::-webkit-scrollbar-thumb {
  background: #cbd5e1;
  border-radius: 10px;
}
</style>
