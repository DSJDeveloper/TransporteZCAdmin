<script setup lang="ts">
import { ref, computed, onMounted } from "vue"
import DataTable from "primevue/datatable"
import Column from "primevue/column"
import FiltroRango from "../components/FiltroRango.vue"
import type { FiltroRango as FiltroRangoType } from "../components/FiltroRango.vue"
import { formatDateTime, formatCurrency, toStr } from "../utils/formatters"
import { getTransactions, exportTransactions } from "../services/transactionService"
import { supabase } from "../services/supabaseClient"
import type { Transaction } from "../services/transactionService"
import type { DataTablePageEvent, DataTableSortEvent } from "primevue/datatable"
import { downloadCSV } from "../utils/exportCsv"
const hoy = toStr(new Date())
const loading = ref(false)
const transactions = ref<Transaction[]>([])
const totalCount = ref(0)
const first = ref(0)
const perPage = ref(10)
const sortField = ref("created_at")
const sortOrder = ref(-1)
const dateFrom = ref<string>(hoy)
const dateTo = ref<string>(hoy)

const unitFilter = ref<number | null>(null)
const statusFilter = ref<number | null>(null)
const units = ref<{ id: number; name: string }[]>([])

const page = computed(() => Math.floor(first.value / perPage.value) + 1)
const fromRecord = computed(() => first.value + 1)
const toRecord = computed(() => Math.min(first.value + perPage.value, totalCount.value))
const totalPages = computed(() => Math.max(1, Math.ceil(totalCount.value / perPage.value)))
const filtroinicial = ref<FiltroRangoType>({
  fechaInicio: hoy,
  fechaFin: hoy,
})
async function loadData() {
  loading.value = true
  try {
    const result = await getTransactions({
      page: page.value,
      perPage: perPage.value,
      filters: {
        dateFrom: dateFrom.value || null,
        dateTo: dateTo.value || null,
        idunit: unitFilter.value,
        status: statusFilter.value,
      },
      sortField: sortField.value,
      sortAsc: sortOrder.value !== -1,
    })
    transactions.value = result.data
    totalCount.value = result.count
  } catch (err) {
    console.error("Error loading transactions:", err)
    transactions.value = []
    totalCount.value = 0
  } finally {
    loading.value = false
  }
}

function onPage(event: DataTablePageEvent) {
  first.value = event.first
  perPage.value = event.rows
  loadData()
}

function onSort(event: DataTableSortEvent) {
  sortField.value = typeof event.sortField === "string" ? event.sortField : "created_at"
  sortOrder.value = event.sortOrder === 1 ? 1 : -1
  first.value = 0
  loadData()
}

function onFiltrarRango(payload: FiltroRangoType) {
  dateFrom.value = payload.fechaInicio
  dateTo.value = payload.fechaFin
  first.value = 0
  loadData()
}

function statusLabel(s: number): string {
  if (s === 0) return "APROBADA"
  if (s === 1) return "RECHAZADA"
  return "RECHAZADA"
}

function statusClass(s: number): string {
  if (s === 1) return "bg-error-container text-on-error-container"
  if (s === 0) return "bg-tertiary-fixed text-on-tertiary-fixed-variant"
  return "bg-error-container text-on-error-container"
}

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
  first.value = (p - 1) * perPage.value
  loadData()
}

async function exportAllData() {
  try {
    const all = await exportTransactions(
      { dateFrom: dateFrom.value || null, dateTo: dateTo.value || null, idunit: unitFilter.value, status: statusFilter.value },
      sortField.value,
      sortOrder.value !== -1,
    )
    const mapped = all.map((t) => ({
      id: t.id,
      fecha: t.created_at,
      horario: t.shedule ?? '',
      cliente: t.clients?.name ?? '',
      monto: t.amount,
      nuevo_saldo: t.newBalanceClient ?? 0,
      estatus: statusLabel(t.status),
    }))
    downloadCSV(
      mapped as unknown as Record<string, unknown>[],
      'historial-movimientos',
      [
        { key: 'id', label: '#' },
        { key: 'fecha', label: 'Fecha y Hora' },
        { key: 'horario', label: 'Horario' },
        { key: 'cliente', label: 'Cliente' },
        { key: 'monto', label: 'Monto' },
        { key: 'nuevo_saldo', label: 'Nuevo Saldo' },
        { key: 'estatus', label: 'Estatus' },
      ],
    )
  } catch (err) {
    console.error('Error exporting data:', err)
  }
}

onMounted(async () => {
  const { data: unitData } = await supabase
    .from("units")
    .select("id, name")
    .order("name")
  if (unitData) units.value = unitData as { id: number; name: string }[]
  await loadData()
})
</script>

<template>
   <div class="p-margin-mobile md:p-margin-desktop min-h-screen space-y-xl">
    <!-- Page Header -->
    <div class="flex flex-col md:flex-row md:items-center justify-between gap-md mb-lg">
      <div>
        <h2 class="font-headline-md text-headline-md text-on-surface">Historial de Movimientos</h2>
        <p class="font-body-md text-body-md text-secondary">Registro completo de cargos de viaje y recargas de saldo.</p>
      </div>
      <div class="flex items-center gap-sm">
        <button
          class="flex items-center gap-xs px-md py-sm bg-white border border-outline-variant rounded-xl font-body-md text-body-md text-primary font-semibold hover:bg-surface-container transition-colors shadow-sm disabled:opacity-40"
          :disabled="loading"
          @click="exportAllData"
        >
          <span class="material-symbols-outlined">download</span>
          Exportar Datos
        </button>
      </div>
    </div>

    <!-- Bento Filter Section -->
    <div class="grid grid-cols-1 md:grid-cols-4 gap-sm mb-xl">
      <div class="md:col-span-2 bg-white p-md rounded-xl border border-outline-variant shadow-sm flex flex-col gap-xs">
        <label class="text-label-md text-secondary uppercase tracking-wider">Rango de Fecha</label>
        <FiltroRango @filtrar="onFiltrarRango" :model-value="filtroinicial"/>
      </div>
      <div class="bg-white p-md rounded-xl border border-outline-variant shadow-sm flex flex-col gap-xs">
        <label class="text-label-md text-secondary uppercase tracking-wider">Unidad</label>
        <select
          v-model="unitFilter"
          class="bg-surface-container-low border-outline-variant rounded-lg font-body-md text-body-md focus:ring-primary focus:border-primary w-full h-10 px-sm"
          @change="first = 0; loadData()"
        >
          <option :value="null">Todas las unidades</option>
          <option v-for="u in units" :key="u.id" :value="u.id">{{ u.name }}</option>
        </select>
      </div>
      <div class="bg-white p-md rounded-xl border border-outline-variant shadow-sm flex flex-col gap-xs">
        <label class="text-label-md text-secondary uppercase tracking-wider">Estatus</label>
        <select
          v-model="statusFilter"
          class="bg-surface-container-low border-outline-variant rounded-lg font-body-md text-body-md focus:ring-primary focus:border-primary w-full h-10 px-sm"
          @change="first = 0; loadData()"
        >
          <option :value="null">Todos los estatus</option>
          
          <option :value="0">Aprobada</option>
          <option :value="1">Rechazada</option>
        </select>
      </div>
    </div>

    <!-- DataTable Container -->
    <div class="bg-white rounded-xl border border-outline-variant shadow-sm overflow-hidden flex flex-col">
      <!-- Header -->
      <div class="p-md border-b border-outline-variant flex justify-between items-center bg-surface-bright">
        <div class="flex items-center gap-md">
          <span class="font-body-md text-body-md font-bold text-on-surface">Resultados</span>
          <div class="px-sm py-base bg-primary-container text-on-primary-container rounded-full text-label-md">
            {{ totalCount }} Registros
          </div>
        </div>
        <div class="flex items-center gap-sm">
          <span class="text-body-md text-secondary hidden sm:inline">Mostrar</span>
          <select
            v-model="perPage"
            class="bg-white border-outline-variant rounded-lg font-body-md py-1"
            @change="first = 0; loadData()"
          >
            <option :value="10">10</option>
            <option :value="25">25</option>
            <option :value="50">50</option>
            <option :value="100">100</option>
            <option :value="150">150</option>
            <option :value="500">500</option>
          </select>
        </div>
      </div>

      <!-- Table (scrollable horizontally on mobile) -->
      <div class="overflow-x-auto custom-scrollbar">
        <DataTable
          :value="transactions"
          :lazy="true"
          :loading="loading"
          :totalRecords="totalCount"
          v-model:first="first"
          v-model:rows="perPage"
          v-model:sortField="sortField"
          v-model:sortOrder="sortOrder"
          @page="onPage"
          @sort="onSort"
          :pt="{
            root: { class: '!border-none' },
            header: { class: '!hidden' },
            paginator: { class: '!hidden' },
            loadingOverlay: { class: '!bg-white/60' },
            thead: { class: 'bg-surface-container' },
            headerRow: { class: 'bg-surface-container' },
            headerCell: {
              class: [
                '!px-sm md:!px-md !py-sm !font-bold !text-label-md !uppercase !tracking-wider !text-on-surface-variant !border-b !border-outline-variant !bg-surface-container !whitespace-nowrap',
                'first:!rounded-none last:!rounded-none',
              ],
            },
            row: {
              class: [
                'hover:bg-surface-container-low transition-colors group !border-t !border-outline-variant',
              ],
            },
            bodyRow: {
              class: [
                'hover:bg-surface-container-low transition-colors group !border-t !border-outline-variant',
              ],
            },
            bodyCell: {
              class: '!px-sm md:!px-md !py-sm !font-body-md !text-body-md !border-none !whitespace-nowrap',
            },
            emptyMessage: {
              class: '!px-md !py-xl !text-center !text-on-surface-variant',
            },
          }"
          stripedRows
          responsiveLayout="scroll"
          dataKey="id"
        >
          <!-- # — hide on mobile -->
          <Column field="id" header="#" :sortable="true"
            :pt="{
              headerCell: { class: 'hidden md:table-cell' },
              bodyCell: { class: 'hidden md:table-cell' },
            }"
          >
            <template #body="{ data }">
              <span class="text-on-surface font-medium">{{ (data as Transaction).id }}</span>
            </template>
          </Column>
          <!-- Fecha y Hora — always visible -->
          <Column field="created_at" header="Fecha y Hora" :sortable="true" style="min-width: 150px">
            <template #body="{ data }">
              <span class="text-secondary">{{ formatDateTime((data as Transaction).created_at) }}</span>
            </template>
          </Column>
          <!-- Horario — hide on mobile -->
          <Column field="shedule" header="Horario" :sortable="true"
            :pt="{
              headerCell: { class: 'hidden md:table-cell' },
              bodyCell: { class: 'hidden md:table-cell' },
            }"
          >
            <template #body="{ data }">
              <span class="text-on-surface">{{ (data as Transaction).shedule ?? "—" }}</span>
            </template>
          </Column>
          <!-- Cliente — always visible -->
          <Column field="clients.name" header="Cliente" :sortable="false" style="min-width: 160px">
            <template #body="{ data }">
              <span class="font-semibold text-on-surface truncate max-w-[180px] md:max-w-none inline-block align-middle">{{ (data as Transaction).clients?.name ?? "—" }}</span>
            </template>
          </Column>
          <!-- Unidad — hide on mobile -->
          <Column field="units.name" header="Unidad" :sortable="false"
            :pt="{
              headerCell: { class: 'hidden md:table-cell' },
              bodyCell: { class: 'hidden md:table-cell' },
            }"
          >
            <template #body="{ data }">
              <span class="text-on-surface">{{ (data as Transaction).units?.name ?? "—" }}</span>
            </template>
          </Column>
          <!-- Monto — always visible -->
          <Column field="amount" header="Monto" :sortable="true" style="width: 100px">
            <template #body="{ data }">
              <span class="text-right block font-medium text-on-surface text-nowrap">{{ formatCurrency((data as Transaction).amount) }}</span>
            </template>
          </Column>
          <!-- Nuevo Saldo — hide on mobile -->
          <Column field="newBalanceClient" header="Nuevo Saldo" :sortable="true"
            :pt="{
              headerCell: { class: 'hidden md:table-cell' },
              bodyCell: { class: 'hidden md:table-cell' },
            }"
          >
            <template #body="{ data }">
              <span
                class="text-right block font-bold text-nowrap"
                :class="((data as Transaction).newBalanceClient ?? 0) >= 0 ? 'text-primary' : 'text-error'"
              >
                {{ (data as Transaction).newBalanceClient != null ? formatCurrency((data as Transaction).newBalanceClient!) : "—" }}
              </span>
            </template>
          </Column>
          <!-- Estatus — always visible -->
          <Column field="status" header="Estatus" :sortable="true" style="width: 100px">
            <template #body="{ data }">
              <div class="flex justify-start md:justify-center">
                <span
                  class="inline-block px-sm py-base rounded-full text-label-md font-bold uppercase whitespace-nowrap"
                  :class="statusClass((data as Transaction).status)"
                >
                  {{ statusLabel((data as Transaction).status) }}
                </span>
              </div>
            </template>
          </Column>

          <!-- Empty / Loading state -->
          <template #empty>
            <div v-if="!loading" class="flex flex-col items-center justify-center py-xl text-center">
              <span class="material-symbols-outlined text-[48px] text-outline-variant mb-sm">receipt_long</span>
              <span class="text-on-surface-variant text-body-md">No se encontraron movimientos</span>
            </div>
            <div v-else class="space-y-sm py-sm">
              <div v-for="i in perPage" :key="i" class="flex gap-md px-sm md:px-md">
                <div class="w-10 h-5 bg-surface-container-high rounded animate-pulse hidden md:block" />
                <div class="w-32 md:w-36 h-5 bg-surface-container-high rounded animate-pulse" />
                <div class="w-16 h-5 bg-surface-container-high rounded animate-pulse hidden md:block" />
                <div class="flex-1 h-5 bg-surface-container-high rounded animate-pulse" />
                <div class="w-20 h-5 bg-surface-container-high rounded animate-pulse hidden md:block" />
                <div class="w-20 md:w-24 h-5 bg-surface-container-high rounded animate-pulse" />
                <div class="w-20 h-5 bg-surface-container-high rounded animate-pulse hidden md:block" />
                <div class="w-20 md:w-24 h-5 bg-surface-container-high rounded animate-pulse" />
              </div>
            </div>
          </template>
        </DataTable>
      </div>

      <!-- Pagination Footer -->
      <div class="p-md bg-surface-bright flex flex-col md:flex-row items-center justify-between gap-md border-t border-outline-variant">
        <p class="font-body-md text-body-md text-secondary text-sm md:text-body-md">
          {{ fromRecord }}–{{ toRecord }} de {{ totalCount }}
        </p>
        <nav class="flex items-center gap-base">
          <button
            class="w-9 h-9 md:w-10 md:h-10 flex items-center justify-center rounded-lg border border-outline-variant hover:bg-surface-container transition-colors disabled:opacity-30"
            :disabled="page <= 1"
            @click="goToPage(page - 1)"
          >
            <span class="material-symbols-outlined text-[18px]">chevron_left</span>
          </button>
          <template v-for="p in pageRange" :key="p">
            <button
              v-if="p === '...'"
              class="px-1 w-9 md:w-10 h-9 md:h-10 flex items-center justify-center text-outline text-label-md"
              disabled
            >
              ...
            </button>
            <button
              v-else
              class="w-9 md:w-10 h-9 md:h-10 flex items-center justify-center rounded-lg font-bold text-sm md:text-body-md transition-colors"
              :class="
                p === page
                  ? 'bg-primary text-white shadow-sm'
                  : 'border border-outline-variant hover:bg-surface-container transition-colors'
              "
              @click="goToPage(p)"
            >
              {{ p }}
            </button>
          </template>
          <button
            class="w-9 h-9 md:w-10 md:h-10 flex items-center justify-center rounded-lg border border-outline-variant hover:bg-surface-container transition-colors disabled:opacity-30"
            :disabled="page >= totalPages"
            @click="goToPage(page + 1)"
          >
            <span class="material-symbols-outlined text-[18px]">chevron_right</span>
          </button>
        </nav>
      </div>
    </div>
  </div>
</template>

<style scoped>
.custom-scrollbar::-webkit-scrollbar {
  height: 8px;
  width: 8px;
}
.custom-scrollbar::-webkit-scrollbar-track {
  background: #f1f1f1;
}
.custom-scrollbar::-webkit-scrollbar-thumb {
  background: #c2c6d8;
  border-radius: 4px;
}
.custom-scrollbar::-webkit-scrollbar-thumb:hover {
  background: #727687;
}
</style>
