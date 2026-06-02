<script setup lang="ts">
import { ref, computed, watch, onMounted } from "vue"
import { useRechargeStore } from "../stores/rechargeStore.ts"
import { useAuthStore } from "../stores/authStore.ts"
import { useToast } from "primevue/usetoast"
import type { Recharge } from "../services/rechargeService.ts"
import FiltroRango from "../components/FiltroRango.vue"
import type { FiltroRango as FiltroRangoType } from "../components/FiltroRango.vue"
import { formatDate, formatDateTime, formatCurrency, toStr } from "../utils/formatters.ts"

const ALLOWED_SORT_FIELDS = ["id", "date", "amount", "method", "status", "client_name"] as const
type SortField = typeof ALLOWED_SORT_FIELDS[number]

const store = useRechargeStore()
const authStore = useAuthStore()
const toast = useToast()

const hoy = toStr(new Date())
const page = ref(1)
const perPage = ref(10)
const statusFilter = ref<number | null>(null)
const methodFilter = ref<string | null>(null)
const dateFrom = ref<string>(hoy)
const dateTo = ref<string>(hoy)

const search = ref("")
const detailRecharge = ref<Recharge | null>(null)
const previewImage = ref<string | null>(null)
const previewPdf = ref<string | null>(null)
const processingId = ref<number | null>(null)
const imgError = ref(false)
const previewImgError = ref(false)

function onImgError() {
  imgError.value = true
}

function onPreviewImgError() {
  previewImgError.value = true
}

const filtroinicial = ref<FiltroRangoType>({
  fechaInicio: hoy,
  fechaFin: hoy,
})
const totalPages = computed(() => Math.max(1, Math.ceil(store.totalCount / perPage.value)))
const fromRecord = computed(() => (page.value - 1) * perPage.value + 1)
const toRecord = computed(() => Math.min(page.value * perPage.value, store.totalCount))

const filtered = computed(() => {
  const q = search.value.toLowerCase().trim()
  if (!q) return store.list
  return store.list.filter(
    (r) =>
      r.clients?.name?.toLowerCase().includes(q) ||
      String(r.id).includes(q) ||
      r.ref?.toLowerCase().includes(q),
  )
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

function goToPage(p: number | string) {
  if (typeof p !== "number") return
  if (p < 1 || p > totalPages.value) return
  page.value = p
}

async function loadPage() {
  await store.fetchRecharges(page.value, perPage.value, {
    status: statusFilter.value,
    method: methodFilter.value,
    dateFrom: dateFrom.value || null,
    dateTo: dateTo.value || null,
  })
}

watch(page, loadPage)
watch(perPage, () => {
  page.value = 1
  loadPage()
})
watch([statusFilter, methodFilter], () => {
  page.value = 1
  loadPage()
})

function onFiltrarRango(payload: FiltroRangoType) {
  dateFrom.value = payload.fechaInicio
  dateTo.value = payload.fechaFin
  page.value = 1
  loadPage()
}

function clearFilters() {
  statusFilter.value = null
  methodFilter.value = null
  dateFrom.value = ""
  dateTo.value = ""
  search.value = ""
  page.value = 1
  loadPage()
}

watch([() => store.sortField, () => store.sortAsc], () => {
  page.value = 1
  loadPage()
})

watch(search, () => {
  page.value = 1
})

const columns = computed<{ key: SortField; label: string; hide?: string }[]>(() => [
  { key: "id", label: "# REF" },
  { key: "date", label: "FECHA" },
  { key: "client_name", label: "CLIENTE" },
  { key: "amount", label: "MONTO" },
  { key: "method", label: "MÉTODO" },
  { key: "status", label: "ESTADO" },
])

function sortIcon(key: SortField): string {
  if (store.sortField !== key) return "unfold_more"
  return store.sortAsc ? "arrow_upward" : "arrow_downward"
}

function toggleSort(key: SortField) {
  store.setSort(key)
}

function initials(name: string): string {
  return name
    .split(" ")
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w.charAt(0).toUpperCase())
    .join("")
}

function statusLabel(s: number): string {
  if (s === 0) return "PENDIENTE"
  if (s === 1) return "APROBADA"
  return "RECHAZADA"
}

function statusClass(s: number): string {
  if (s === 0) return "bg-amber-100 text-amber-800"
  if (s === 1) return "bg-tertiary-container/20 text-tertiary-container"
  return "bg-error-container text-on-error-container"
}

function canAct(s: number): boolean {
  return s === 0
}

function getMethodLabel(m: string): string {
  const map: Record<string, string> = {
    efectivo: "Efectivo $",
    pago_movil: "Pago Movil",
    "pago móvil": "Pago Movil",
    pago_móvil: "Pago Movil",
  }
  return map[m.toLowerCase()] ?? m
}

function fmtDateTime(d: string | null | undefined): string {
  if (!d) return "—"
  return formatDateTime(d)
}

function openDetail(r: Recharge) {
  detailRecharge.value = r
  imgError.value = false
}

function closeDetail() {
  detailRecharge.value = null
  previewImage.value = null
  previewPdf.value = null
}

function openImagePreview(pic: string) {
  previewImage.value = pic
  previewImgError.value = false
}

function openPdfPreview(pic: string) {
  previewPdf.value = pic
}

function isPdf(url: string): boolean {
  return url.toLowerCase().endsWith(".pdf")
}

async function handleAction(r: Recharge, action: "approve" | "reject") {
  if (processingId.value) return
  processingId.value = r.id
  try {
    const userName = authStore.user?.name ?? "Admin"
    const ok = await store.processRecharge(r.id, action, userName)
    if (ok) {
      toast.add({
        severity: action === "approve" ? "success" : "warn",
        summary: action === "approve" ? "Aprobada" : "Rechazada",
        detail: `Recarga #${r.id} ${action === "approve" ? "aprobada" : "rechazada"} correctamente.`,
        life: 3000,
      })
    } else {
      toast.add({
        severity: "error",
        summary: "Error",
        detail: store.error ?? "No se pudo procesar la recarga.",
        life: 4000,
      })
    }
  } finally {
    processingId.value = null
  }
}

onMounted(async () => {
  await Promise.all([store.fetchStats(), store.fetchRecharges(1, perPage.value, {
    status: statusFilter.value,
    method: methodFilter.value,
    dateFrom: dateFrom.value || null,
    dateTo: dateTo.value || null,
  })])
})
</script>

<template>
  <div class="p-margin-mobile md:p-margin-desktop min-h-screen space-y-xl">
    <!-- Header -->
    <div class="flex flex-col sm:flex-row sm:justify-between sm:items-end gap-md">
      <div>
        <h2 class="font-headline-lg text-headline-lg text-on-surface">Gestión de Recargas</h2>
        <p class="font-body-lg text-body-lg text-on-surface-variant hidden sm:block">
          Supervise el flujo de caja y apruebe transacciones entrantes.
        </p>
      </div>
    </div>

    <!-- KPI Bento Grid -->
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-lg">
      <div
        class="bg-surface-container-lowest/70 backdrop-blur-sm border border-outline-variant/60 bento-item p-lg rounded-xl flex flex-col border-l-4 border-l-amber-500">
        <div class="flex justify-between items-start mb-base">
          <span class="text-amber-600 font-label-md text-label-md uppercase tracking-wider">POR APROBAR</span>
          <span class="material-symbols-outlined text-amber-500">pending_actions</span>
        </div>
        <div v-if="store.statsLoading" class="h-8 w-20 bg-surface-container-high rounded animate-pulse"></div>
        <div v-else class="text-headline-lg font-bold text-on-surface">{{ store.stats.pending }}</div>
        <p class="text-label-md text-on-surface-variant">Acción requerida inmediata</p>
      </div>
      <div
        class="bg-surface-container-lowest/70 backdrop-blur-sm border border-outline-variant/60 bento-item p-lg rounded-xl flex flex-col border-l-4 border-l-error">
        <div class="flex justify-between items-start mb-base">
          <span class="text-error font-label-md text-label-md uppercase tracking-wider">RECHAZADOS</span>
          <span class="material-symbols-outlined text-error">cancel</span>
        </div>
        <div v-if="store.statsLoading" class="h-8 w-20 bg-surface-container-high rounded animate-pulse"></div>
        <div v-else class="text-headline-lg font-bold text-on-surface">{{ store.stats.rejected }}</div>
        <p class="text-label-md text-on-surface-variant">Histórico total</p>
      </div>
      <div
        class="bg-surface-container-lowest/70 backdrop-blur-sm border border-outline-variant/60 bento-item p-lg rounded-xl flex flex-col border-l-4 border-l-tertiary">
        <div class="flex justify-between items-start mb-base">
          <span class="text-tertiary font-label-md text-label-md uppercase tracking-wider">APROBADOS</span>
          <span class="material-symbols-outlined text-tertiary">check_circle</span>
        </div>
        <div v-if="store.statsLoading" class="h-8 w-20 bg-surface-container-high rounded animate-pulse"></div>
        <div v-else class="text-headline-lg font-bold text-on-surface">{{ store.stats.approved }}</div>
        <p class="text-label-md text-on-surface-variant">Histórico total</p>
      </div>
      <div
        class="bg-surface-container-lowest/70 backdrop-blur-sm border border-outline-variant/60 bento-item p-lg rounded-xl flex flex-col border-l-4 border-l-primary bg-primary/5">
        <div class="flex justify-between items-start mb-base">
          <span class="text-primary font-label-md text-label-md uppercase tracking-wider">MONTO TOTAL</span>
          <span class="material-symbols-outlined text-primary">payments</span>
        </div>
        <div v-if="store.statsLoading" class="h-8 w-28 bg-surface-container-high rounded animate-pulse"></div>
        <div v-else class="text-headline-lg font-bold text-on-surface">{{ formatCurrency(store.stats.total_amount) }}
        </div>
        <p class="text-label-md text-on-surface-variant">Acumulados aprobados</p>
      </div>
    </div>

    <!-- Filters -->
    <div class="bg-surface-container-lowest/70 backdrop-blur-sm border border-outline-variant/60 p-lg rounded-xl">
      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-5 gap-md items-end">
        <!-- Date range -->
        <div class="lg:col-span-2">
          <label
            class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base ml-1">Rango
            de Fecha</label>
          <FiltroRango @filtrar="onFiltrarRango" :model-value="filtroinicial" />
        </div>

        <!-- Status -->
        <div>
          <label
            class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base ml-1">Estatus</label>
          <select v-model="statusFilter"
            class="w-full h-10 px-sm bg-surface-container-lowest border border-outline-variant rounded-xl text-body-md outline-none focus:ring-2 focus:ring-primary transition-all">
            <option :value="null">Todos</option>
            <option :value="0">Pendiente</option>
            <option :value="1">Aprobada</option>
            <option :value="2">Rechazada</option>
          </select>
        </div>

        <!-- Method -->
        <div>
          <label
            class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base ml-1">Método</label>
          <select v-model="methodFilter"
            class="w-full h-10 px-sm bg-surface-container-lowest border border-outline-variant rounded-xl text-body-md outline-none focus:ring-2 focus:ring-primary transition-all">
            <option :value="null">Todos</option>
            <option value="efectivo">Efectivo $</option>
            <option value="pago_movil">Pago Movil</option>
          </select>
        </div>

      </div>

      <!-- Search + Clear -->
      <div class="flex items-center gap-md mt-md">
        <div class="relative flex-1">
          <span
            class="material-symbols-outlined absolute left-3 top-1/2 -translate-y-1/2 text-outline text-[18px]">search</span>
          <input v-model="search" placeholder="Buscar por cliente, ref o ID..." type="text"
            class="w-full h-10 pl-9 pr-3 bg-surface-container-lowest border border-outline-variant rounded-xl text-body-md outline-none focus:ring-2 focus:ring-primary transition-all" />
        </div>
        <button
          class="h-10 px-md rounded-xl border border-outline-variant text-on-surface-variant font-bold text-[13px] hover:bg-surface-container transition-all shrink-0 flex items-center gap-1"
          @click="clearFilters">
          <span class="material-symbols-outlined text-[18px]">restart_alt</span>
          Limpiar
        </button>
      </div>
    </div>

    <!-- Table Section -->
    <section class="bg-surface-container-lowest rounded-xl border border-outline-variant shadow-sm overflow-hidden">
      <div
        class="p-md md:p-lg border-b border-outline-variant flex flex-col md:flex-row md:items-center md:justify-between gap-md bg-surface-container-low/30">
        <h4 class="font-headline-sm text-headline-sm text-on-surface">Lista de Recargas</h4>
        <div class="flex items-center gap-md w-full md:w-auto">
          <div class="flex items-center gap-xs text-body-md text-on-surface-variant whitespace-nowrap">
            <span class="hidden md:inline">Mostrar</span>
            <select v-model.number="perPage"
              class="bg-surface-container-lowest border border-outline-variant rounded-lg text-body-md py-1 pl-2 pr-1 focus:ring-primary outline-none">
                   <option :value="10">10</option>
            <option :value="25">25</option>
            <option :value="50">50</option>
            <option :value="100">100</option>
            <option :value="150">150</option>
            <option :value="500">500</option>
            </select>
            <span class="hidden md:inline">registros</span>
          </div>
        </div>
      </div>

      <!-- Loading skeleton -->
      <div v-if="store.loading && !store.list.length" class="p-lg space-y-md">
        <div v-for="i in 4" :key="i" class="flex items-center gap-lg animate-pulse">
          <div class="h-4 w-12 bg-surface-container-high rounded"></div>
          <div class="h-4 w-24 bg-surface-container-high rounded"></div>
          <div class="h-4 w-40 bg-surface-container-high rounded"></div>
          <div class="h-4 w-16 bg-surface-container-high rounded ml-auto"></div>
          <div class="h-4 w-20 bg-surface-container-high rounded"></div>
          <div class="h-6 w-20 bg-surface-container-high rounded-full"></div>
          <div class="flex gap-xs ml-auto">
            <div class="h-8 w-8 bg-surface-container-high rounded-lg"></div>
            <div class="h-8 w-8 bg-surface-container-high rounded-lg"></div>
            <div class="h-8 w-8 bg-surface-container-high rounded-lg"></div>
          </div>
        </div>
      </div>

      <!-- Empty state -->
      <div v-else-if="!filtered.length && !store.loading" class="p-xl text-center text-on-surface-variant">
        <span class="material-symbols-outlined text-[48px] text-outline">account_balance_wallet</span>
        <p class="mt-2">No se encontraron recargas</p>
      </div>

      <!-- Data -->
      <template v-else>
        <!-- Desktop table -->
        <div class="hidden md:block overflow-x-auto">
          <table class="w-full text-left font-body-md text-body-md border-collapse">
            <thead class="bg-surface-container-high/20 border-b border-outline-variant">
              <tr>
                <th v-for="col in columns" :key="col.key"
                  class="px-lg py-md font-bold text-on-surface-variant uppercase text-[11px] tracking-widest cursor-pointer select-none hover:text-on-surface transition-colors"
                  @click="toggleSort(col.key)">
                  <span class="flex items-center gap-1">
                    {{ col.label }}
                    <span class="material-symbols-outlined text-[14px] leading-none"
                      :class="store.sortField === col.key ? 'text-primary' : 'text-outline/40'">{{ sortIcon(col.key)
                      }}</span>
                  </span>
                </th>
                <th
                  class="px-lg py-md font-bold text-on-surface-variant uppercase text-[11px] tracking-widest text-right">
                  ACCIONES</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-outline-variant">
              <tr v-for="r in filtered" :key="r.id" class="hover:bg-primary-container/5 transition-colors group">
                <td class="px-lg py-md font-bold text-on-surface">{{ r.id }}</td>
                <td class="px-lg py-md text-on-surface-variant text-[13px]">{{ formatDate(r.date) }}</td>
                <td class="px-lg py-md">
                  <div class="flex items-center gap-sm">
                    <div
                      class="w-8 h-8 rounded-full bg-secondary-container flex items-center justify-center text-secondary font-bold text-[11px] shrink-0">
                      {{ r.clients ? initials(r.clients.name) : "??" }}</div>
                    <span class="text-on-surface font-medium">{{ r.clients?.name ?? "—" }}</span>
                  </div>
                </td>
                <td class="px-lg py-md font-bold text-on-surface">
                  {{ formatCurrency(r.amount) }}
                  <span v-if="r.tasa && r.tasa > 0" class="text-[11px] text-outline ml-1">@ {{ r.tasa }}</span>
                </td>
                <td class="px-lg py-md text-on-surface-variant">{{ getMethodLabel(r.method) }}</td>
                <td class="px-lg py-md">
                  <span class="px-sm py-[2px] rounded-full text-[11px] font-bold uppercase tracking-wider"
                    :class="statusClass(r.status)">{{ statusLabel(r.status) }}</span>
                </td>
                <td class="px-lg py-md text-right">
                  <div class="flex justify-end gap-xs">
                    <button
                      class="w-8 h-8 rounded-lg flex items-center justify-center text-primary hover:bg-primary/10 transition-colors"
                      title="Ver Detalle" @click="openDetail(r)">
                      <span class="material-symbols-outlined text-[20px]">visibility</span>
                    </button>
                    <button v-if="canAct(r.status)"
                      class="w-8 h-8 rounded-lg flex items-center justify-center text-tertiary hover:bg-tertiary/10 transition-colors disabled:opacity-40"
                      title="Aprobar" :disabled="processingId === r.id" @click="handleAction(r, 'approve')">
                      <span class="material-symbols-outlined text-[20px]">check_circle</span>
                    </button>
                    <button v-if="canAct(r.status)"
                      class="w-8 h-8 rounded-lg flex items-center justify-center text-error hover:bg-error/10 transition-colors disabled:opacity-40"
                      title="Rechazar" :disabled="processingId === r.id" @click="handleAction(r, 'reject')">
                      <span class="material-symbols-outlined text-[20px]">do_not_disturb_on</span>
                    </button>
                    <span v-if="!canAct(r.status)"
                      class="w-8 h-8 rounded-lg flex items-center justify-center text-outline-variant cursor-not-allowed"
                      title="No disponible">
                      <span class="material-symbols-outlined text-[20px]">block</span>
                    </span>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <!-- Mobile cards -->
        <div class="md:hidden divide-y divide-outline-variant">
          <div v-for="r in filtered" :key="r.id" class="p-md space-y-sm">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-sm">
                <div
                  class="w-8 h-8 rounded-full bg-secondary-container flex items-center justify-center text-secondary font-bold text-[11px] shrink-0">
                  {{ r.clients ? initials(r.clients.name) : "??" }}</div>
                <div>
                  <span class="font-bold text-on-surface text-[13px]">#{{ r.id }}</span>
                  <span class="ml-2 text-label-md text-outline">{{ formatDate(r.date) }}</span>
                </div>
              </div>
              <span class="px-2 py-[2px] rounded-full text-[10px] font-bold uppercase tracking-wider"
                :class="statusClass(r.status)">{{ statusLabel(r.status) }}</span>
            </div>
            <div class="text-on-surface-variant text-body-md">
              <span class="font-medium text-on-surface">{{ r.clients?.name ?? "—" }}</span>
            </div>
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2 text-body-md">
                <span class="font-bold text-on-surface">{{ formatCurrency(r.amount) }}</span>
                <span class="text-outline text-[12px]">{{ getMethodLabel(r.method) }}</span>
              </div>
              <div class="flex gap-1">
                <button
                  class="w-7 h-7 rounded-lg flex items-center justify-center text-primary hover:bg-primary/10 transition-colors text-[16px]"
                  title="Ver Detalle" @click="openDetail(r)">
                  <span class="material-symbols-outlined text-[18px]">visibility</span>
                </button>
                <button v-if="canAct(r.status)"
                  class="w-7 h-7 rounded-lg flex items-center justify-center text-tertiary hover:bg-tertiary/10 transition-colors disabled:opacity-40"
                  title="Aprobar" :disabled="processingId === r.id" @click="handleAction(r, 'approve')">
                  <span class="material-symbols-outlined text-[18px]">check_circle</span>
                </button>
                <button v-if="canAct(r.status)"
                  class="w-7 h-7 rounded-lg flex items-center justify-center text-error hover:bg-error/10 transition-colors disabled:opacity-40"
                  title="Rechazar" :disabled="processingId === r.id" @click="handleAction(r, 'reject')">
                  <span class="material-symbols-outlined text-[18px]">do_not_disturb_on</span>
                </button>
              </div>
            </div>
          </div>
        </div>
      </template>

      <!-- Pagination -->
      <div
        class="p-md md:p-lg border-t border-outline-variant flex flex-col md:flex-row items-center justify-between gap-md bg-surface-container-low/20">
        <p class="font-body-md text-body-md text-on-surface-variant text-center md:text-left">
          Mostrando <span class="font-bold text-on-surface">{{ fromRecord }}-{{ toRecord }}</span> de
          <span class="font-bold text-on-surface">{{ store.totalCount }}</span> registros
        </p>
        <div class="flex items-center gap-xs">
          <button
            class="p-xs rounded-lg hover:bg-surface-container-high text-secondary disabled:opacity-30 transition-colors"
            :disabled="page <= 1" @click="goToPage(page - 1)">
            <span class="material-symbols-outlined">chevron_left</span>
          </button>
          <div class="flex gap-xs">
            <template v-for="p in pageRange" :key="p">
              <button v-if="p === '...'" class="px-1 self-center text-outline text-label-md" disabled>...</button>
              <button v-else class="w-8 h-8 rounded-lg text-label-md font-bold transition-colors"
                :class="p === page ? 'bg-primary text-on-primary' : 'hover:bg-surface-container-high text-on-surface-variant'"
                @click="goToPage(p)">{{ p }}</button>
            </template>
          </div>
          <button
            class="p-xs rounded-lg hover:bg-surface-container-high text-secondary disabled:opacity-30 transition-colors"
            :disabled="page >= totalPages" @click="goToPage(page + 1)">
            <span class="material-symbols-outlined">chevron_right</span>
          </button>
        </div>
      </div>
    </section>

    <!-- Detail Modal -->
    <Teleport to="body">
      <div v-if="detailRecharge" class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" @click="closeDetail"></div>
        <div class="relative w-full max-w-3xl mx-auto max-h-[90vh] flex flex-col" @click.stop>
          <div
            class="bg-surface-container-lowest rounded-xl shadow-2xl border border-outline-variant overflow-hidden flex flex-col max-h-[90vh]">
            <!-- Header -->
            <div class="flex items-center justify-between p-md md:p-lg border-b border-outline-variant shrink-0">
              <div class="flex items-center gap-md">
                <div class="w-10 h-10 rounded-full bg-primary/10 flex items-center justify-center text-primary">
                  <span class="material-symbols-outlined">receipt_long</span>
                </div>
                <div>
                  <h3 class="font-headline-sm text-headline-sm text-on-surface">Detalle de Recarga #{{ detailRecharge.id
                    }}
                  </h3>
                  <p class="text-label-md text-on-surface-variant">{{ fmtDateTime(detailRecharge.createAt) }}</p>
                </div>
              </div>
              <button class="text-outline hover:text-on-surface transition-colors" @click="closeDetail">
                <span class="material-symbols-outlined">close</span>
              </button>
            </div>

            <!-- Body -->
            <div class="overflow-y-auto p-md md:p-lg space-y-lg">
              <!-- Info grid -->
              <div class="grid grid-cols-1 md:grid-cols-2 gap-lg">
                <div class="space-y-md">
                  <div>
                    <label
                      class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Cliente</label>
                    <div class="flex items-center gap-sm">
                      <div
                        class="w-9 h-9 rounded-full bg-secondary-container flex items-center justify-center text-secondary font-bold text-[12px] shrink-0">
                        {{ detailRecharge.clients ? initials(detailRecharge.clients.name) : "??" }}
                      </div>
                      <span class="font-bold text-on-surface text-body-md">{{ detailRecharge.clients?.name ?? "—"
                        }}</span>
                    </div>
                  </div>
                  <div>
                    <label
                      class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Método
                      de Pago</label>
                    <div class="flex items-center gap-sm">
                      <span class="material-symbols-outlined text-outline">
                        {{ detailRecharge.method.toLowerCase().includes("efectivo") ? "payments" : "phone_android" }}
                      </span>
                      <span class="text-on-surface font-medium">{{ getMethodLabel(detailRecharge.method) }}</span>
                    </div>
                  </div>
                  <div v-if="detailRecharge.ref">
                    <label
                      class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Referencia</label>
                    <div class="flex items-center gap-sm">
                      <span class="material-symbols-outlined text-outline">tag</span>
                      <code class="bg-surface-container-high px-sm py-xs rounded text-primary font-bold text-body-md">{{
                    detailRecharge.ref }}</code>
                    </div>
                  </div>
                  <div>
                    <label
                      class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Registrado
                      por</label>
                    <div class="flex items-center gap-sm">
                      <span class="material-symbols-outlined text-outline">person</span>
                      <span class="text-on-surface">{{ detailRecharge.createBy ?? "—" }}</span>
                    </div>
                  </div>
                </div>
                <div class="space-y-md">
                  <div>
                    <label
                      class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Monto</label>
                    <div class="text-[28px] font-bold text-on-surface">
                      {{ formatCurrency(detailRecharge.amount) }}
                      <span class="text-body-md text-outline font-normal">USD</span>
                    </div>
                  </div>
                  <div v-if="detailRecharge.tasa && detailRecharge.tasa > 0">
                    <label
                      class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Tasa
                      de Cambio</label>
                    <div class="flex items-center gap-sm">
                      <span class="material-symbols-outlined text-outline">currency_exchange</span>
                      <span class="text-on-surface font-bold text-body-md">1 USD = {{
                        formatCurrency(detailRecharge.tasa,
                        'es-VE', 'VES') }}</span>
                    </div>
                  </div>
                  <div>
                    <label
                      class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Fecha</label>
                    <div class="flex items-center gap-sm">
                      <span class="material-symbols-outlined text-outline">calendar_today</span>
                      <span class="text-on-surface">{{ formatDate(detailRecharge.date) }}</span>
                    </div>
                  </div>
                  <div>
                    <label
                      class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Estado</label>
                    <span class="px-md py-sm rounded-full text-[12px] font-bold uppercase tracking-wider inline-block"
                      :class="statusClass(detailRecharge.status)">{{ statusLabel(detailRecharge.status) }}</span>
                  </div>
                  <div v-if="detailRecharge.status !== 0 && detailRecharge.updateAprobate">
                    <label
                      class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Procesado
                      el</label>
                    <div class="flex items-center gap-sm">
                      <span class="material-symbols-outlined text-outline">check_circle</span>
                      <span class="text-on-surface">{{ fmtDateTime(detailRecharge.updateAprobate) }}</span>
                    </div>
                  </div>
                </div>
              </div>

              <!-- Comprobante -->
              <div v-if="detailRecharge.picture" class="border-t border-outline-variant pt-lg">
                <label
                  class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-md">Comprobante
                  de Pago</label>
                <div
                  class="bg-surface-container-low/50 rounded-xl border border-outline-variant overflow-hidden cursor-pointer hover:bg-surface-container-low transition-colors"
                  @click="isPdf(detailRecharge.picture!) ? openPdfPreview(detailRecharge.picture!) : openImagePreview(detailRecharge.picture!)">
                  <div v-if="isPdf(detailRecharge.picture!)"
                    class="flex flex-col items-center justify-center py-xl text-center">
                    <span class="material-symbols-outlined text-[64px] text-error">picture_as_pdf</span>
                    <span class="text-on-surface-variant text-body-md mt-sm">Ver PDF del comprobante</span>
                    <span class="text-label-md text-primary font-bold mt-xs">Abrir documento →</span>
                  </div>
                  <img v-else v-show="!imgError" :src="detailRecharge.picture" alt="Comprobante de pago"
                    class="w-full max-h-64 object-contain bg-white" @error="onImgError" />
                  <div v-if="imgError"
                    class="flex flex-col items-center justify-center py-xl text-center bg-surface-container-low/50 rounded-xl border border-dashed border-outline-variant">
                    <span class="material-symbols-outlined text-[48px] text-error">broken_image</span>
                    <span class="text-on-surface-variant text-body-md mt-sm">No se pudo cargar la imagen</span>
                    <span class="text-label-md text-outline mt-xs">El comprobante no está disponible</span>
                  </div>
                </div>
              </div>
              <div v-else class="border-t border-outline-variant pt-lg">
                <label
                  class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-md">Comprobante
                  de Pago</label>
                <div
                  class="flex flex-col items-center justify-center py-xl text-center bg-surface-container-low/50 rounded-xl border border-dashed border-outline-variant">
                  <span class="material-symbols-outlined text-[48px] text-outline-variant">image_not_supported</span>
                  <span class="text-on-surface-variant text-body-md mt-sm">Sin comprobante adjunto</span>
                </div>
              </div>
            </div>

            <!-- Footer actions -->
            <div v-if="canAct(detailRecharge.status)"
              class="border-t border-outline-variant p-md md:p-lg flex flex-col-reverse sm:flex-row justify-end gap-md shrink-0 bg-surface-container-low/20">
              <button
                class="h-11 px-lg rounded-xl border border-outline-variant text-on-surface-variant font-bold hover:bg-surface-container transition-all"
                @click="closeDetail">Cerrar</button>
              <button
                class="h-11 px-lg rounded-xl bg-error text-on-error font-bold hover:shadow-lg active:scale-[0.98] transition-all flex items-center justify-center gap-xs disabled:opacity-50"
                :disabled="processingId === detailRecharge.id"
                @click="handleAction(detailRecharge, 'reject'); closeDetail()">
                <span class="material-symbols-outlined text-[18px]">do_not_disturb_on</span>
                Rechazar
              </button>
              <button
                class="h-11 px-lg rounded-xl bg-tertiary text-on-tertiary font-bold hover:shadow-lg active:scale-[0.98] transition-all flex items-center justify-center gap-xs disabled:opacity-50"
                :disabled="processingId === detailRecharge.id"
                @click="handleAction(detailRecharge, 'approve'); closeDetail()">
                <span class="material-symbols-outlined text-[18px]">check_circle</span>
                Aprobar
              </button>
            </div>
            <div v-else
              class="border-t border-outline-variant p-md md:p-lg flex justify-end shrink-0 bg-surface-container-low/20">
              <button
                class="h-11 px-lg rounded-xl border border-outline-variant text-on-surface-variant font-bold hover:bg-surface-container transition-all"
                @click="closeDetail">Cerrar</button>
            </div>
          </div>
        </div>
      </div>
    </Teleport>

    <!-- Image Preview Overlay (from detail modal) -->
    <Teleport to="body">
      <div v-if="previewImage" class="fixed inset-0 z-[60] flex items-center justify-center p-4"
        @click="previewImage = null">
        <div class="absolute inset-0 bg-black/80 backdrop-blur-sm"></div>
          <div class="relative max-w-4xl max-h-[90vh] w-full mx-auto flex items-center justify-center" @click.stop>
            <button class="absolute -top-10 right-0 text-white/80 hover:text-white transition-colors"
              @click="previewImage = null">
              <span class="material-symbols-outlined text-[28px]">close</span>
            </button>
            <img v-show="!previewImgError" :src="previewImage" alt="Comprobante de pago"
              class="w-full max-h-[85vh] object-contain rounded-xl" @error="onPreviewImgError" />
            <div v-if="previewImgError"
              class="flex flex-col items-center justify-center py-16 text-center">
              <span class="material-symbols-outlined text-[64px] text-error">broken_image</span>
              <span class="text-white text-body-lg mt-sm">No se pudo cargar la imagen</span>
              <span class="text-white/60 text-label-md mt-xs">El comprobante no está disponible</span>
            </div>
          </div>
      </div>
    </Teleport>

    <!-- PDF Preview Overlay (from detail modal) -->
    <Teleport to="body">
      <div v-if="previewPdf" class="fixed inset-0 z-[60] flex items-center justify-center p-4"
        @click="previewPdf = null">
        <div class="absolute inset-0 bg-black/80 backdrop-blur-sm"></div>
        <div class="relative w-full max-w-4xl max-h-[90vh] mx-auto flex flex-col" @click.stop>
          <div class="flex items-center justify-between mb-md">
            <span class="text-white font-bold">Comprobante PDF</span>
            <button class="text-white/80 hover:text-white transition-colors" @click="previewPdf = null">
              <span class="material-symbols-outlined text-[28px]">close</span>
            </button>
          </div>
          <iframe :src="previewPdf" class="w-full h-[80vh] rounded-xl bg-white"></iframe>
        </div>
      </div>
    </Teleport>

    <!-- Toast -->
    <Toast position="top-right" />
  </div>
</template>

<style scoped>
.bento-item {
  transition: all 0.3s ease;
}

.bento-item:hover {
  transform: translateY(-2px);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.08);
}
</style>
