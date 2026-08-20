<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { supabase } from '@/services/supabaseClient'
import Chart from 'primevue/chart'
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  BarElement,
  PointElement,
  LineElement,
  Title,
  Tooltip,
  Legend,
  Filler,
} from 'chart.js'
import { formatCurrency, formatCount } from '@/utils/formatters'
import { downloadCSV } from '@/utils/exportCsv'
import StatCard from '@/components/dashboard/StatCard.vue'

ChartJS.register(CategoryScale, LinearScale, BarElement, PointElement, LineElement, Title, Tooltip, Legend, Filler)

interface DailyData {
  day: string
  transactions: number
  transactions_amount: number
  recharges: number
  recharges_amount: number
}

interface TopClient {
  name: string
  count: number
  total: number
}

interface MonthlySummary {
  total_transactions: number
  total_recharges: number
  transactions_amount: number
  recharges_amount: number
  active_clients: number
  daily_data: DailyData[]
  top_clients: TopClient[]
}

const now = new Date()
const selectedYear = ref(now.getFullYear())
const selectedMonth = ref(now.getMonth() + 1)
const loading = ref(true)
const summary = ref<MonthlySummary | null>(null)

const monthNames = [
  'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
  'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre',
]

const monthLabel = computed(() => `${monthNames[selectedMonth.value - 1]} ${selectedYear.value}`)

const yearOptions = computed(() => {
  const years = []
  for (let y = now.getFullYear() - 3; y <= now.getFullYear() + 1; y++) {
    years.push(y)
  }
  return years
})

async function loadSummary() {
  loading.value = true
  try {
    const { data } = await supabase.rpc('get_monthly_summary', {
      p_year: selectedYear.value,
      p_month: selectedMonth.value,
    })
    summary.value = data as MonthlySummary
  } catch (err) {
    console.error('Error loading monthly summary:', err)
  } finally {
    loading.value = false
  }
}

const chartData = computed(() => {
  const days = summary.value?.daily_data ?? []
  const labels = days.map((d) => {
    const parts = d.day.split('-')
    if (parts.length === 3) return `${parseInt(parts[2] ?? '0')}`
    return d.day
  })
  return {
    labels,
    datasets: [
      {
        label: 'Transacciones',
        data: days.map((d) => d.transactions),
        backgroundColor: '#0050cb',
        borderRadius: 2,
        barThickness: 12,
      },
      {
        label: 'Recargas',
        data: days.map((d) => d.recharges),
        backgroundColor: '#008259',
        borderRadius: 2,
        barThickness: 12,
      },
    ],
  }
})

const chartOptions = {
  responsive: true,
  maintainAspectRatio: false,
  plugins: {
    legend: {
      position: 'top' as const,
      labels: {
        usePointStyle: true,
        font: { size: 11 },
      },
    },
    tooltip: {
      mode: 'index' as const,
      intersect: false,
    },
  },
  scales: {
    x: {
      grid: { display: false },
      ticks: { font: { size: 10 } },
    },
    y: {
      beginAtZero: true,
      ticks: { stepSize: 1, font: { size: 10 } },
      grid: { color: '#e5eeff' },
    },
  },
}

function exportToCSV() {
  if (!summary.value) return
  const data = summary.value.daily_data.map((d) => ({
    dia: d.day,
    transacciones: d.transactions,
    monto_transacciones: d.transactions_amount,
    recargas: d.recharges,
    monto_recargas: d.recharges_amount,
  }))
  downloadCSV(
    data as unknown as Record<string, unknown>[],
    `analisis-mensual-${selectedYear.value}-${String(selectedMonth.value).padStart(2, '0')}`,
    [
      { key: 'dia', label: 'Día' },
      { key: 'transacciones', label: 'Transacciones' },
      { key: 'monto_transacciones', label: 'Monto Transacciones' },
      { key: 'recargas', label: 'Recargas' },
      { key: 'monto_recargas', label: 'Monto Recargas' },
    ],
  )
}

function exportTopClients() {
  if (!summary.value) return
  const data = summary.value.top_clients.map((c) => ({
    cliente: c.name,
    transacciones: c.count,
    total: c.total,
  }))
  downloadCSV(
    data as unknown as Record<string, unknown>[],
    `top-clientes-${selectedYear.value}-${String(selectedMonth.value).padStart(2, '0')}`,
    [
      { key: 'cliente', label: 'Cliente' },
      { key: 'transacciones', label: 'Transacciones' },
      { key: 'total', label: 'Total' },
    ],
  )
}

onMounted(loadSummary)
</script>

<template>
  <div class="p-margin-desktop space-y-xl">
    <!-- Header -->
    <div class="flex flex-col md:flex-row md:items-center justify-between gap-md">
      <div>
        <h2 class="font-headline-lg text-headline-lg text-on-surface">Análisis Mensual</h2>
        <p class="font-body-lg text-body-lg text-on-surface-variant">Reporte completo del {{ monthLabel }}</p>
      </div>
      <div class="flex items-center gap-sm">
        <select
          v-model="selectedMonth"
          class="border border-outline-variant rounded-lg px-sm py-1 text-body-md bg-transparent"
          @change="loadSummary"
        >
          <option v-for="(m, i) in monthNames" :key="i" :value="i + 1">{{ m }}</option>
        </select>
        <select
          v-model="selectedYear"
          class="border border-outline-variant rounded-lg px-sm py-1 text-body-md bg-transparent"
          @change="loadSummary"
        >
          <option v-for="y in yearOptions" :key="y" :value="y">{{ y }}</option>
        </select>
        <button
          class="flex items-center gap-xs px-md py-sm bg-primary text-white rounded-lg text-label-md font-bold hover:bg-primary/90 transition-colors"
          :disabled="loading || !summary"
          @click="exportToCSV"
        >
          <span class="material-symbols-outlined !text-sm">download</span>
          Exportar CSV
        </button>
      </div>
    </div>

    <!-- KPI Cards -->
    <div class="grid grid-cols-2 md:grid-cols-4 gap-lg">
      <StatCard
        :loading="loading"
        label="TRANSACCIONES"
        :value="formatCount(summary?.total_transactions ?? 0)"
        icon="swap_horiz"
        color="primary"
      />
      <StatCard
        :loading="loading"
        label="RECARGAS"
        :value="formatCount(summary?.total_recharges ?? 0)"
        icon="payments"
        color="tertiary"
      />
      <StatCard
        :loading="loading"
        label="MONTO TRANSACCIONES"
        :value="formatCurrency(summary?.transactions_amount ?? 0)"
        icon="trending_up"
        color="error"
      />
      <StatCard
        :loading="loading"
        label="MONTO RECARGAS"
        :value="formatCurrency(summary?.recharges_amount ?? 0)"
        icon="account_balance"
        color="warning"
      />
    </div>

    <!-- Daily Chart -->
    <div class="bg-surface-container-lowest border border-outline-variant rounded-xl p-lg shadow-sm">
      <div class="flex items-center justify-between mb-lg">
        <h3 class="font-headline-sm text-headline-sm text-on-surface">Desglose Diario</h3>
        <span class="text-body-md text-on-surface-variant">{{ summary?.active_clients ?? 0 }} clientes activos</span>
      </div>

      <div v-if="loading" class="h-72 flex items-center justify-center">
        <span class="material-symbols-outlined animate-spin text-outline">refresh</span>
      </div>

      <div v-else-if="!summary?.daily_data?.length" class="h-72 flex items-center justify-center text-on-surface-variant">
        Sin datos para este mes
      </div>

      <div v-else class="h-96">
        <Chart type="bar" :data="chartData" :options="chartOptions" class="h-full" />
      </div>
    </div>

    <!-- Top Clients -->
    <div class="bg-surface-container-lowest border border-outline-variant rounded-xl shadow-sm overflow-hidden">
      <div class="flex items-center justify-between px-lg py-md border-b border-outline-variant">
        <h3 class="font-headline-sm text-headline-sm text-on-surface">Top Clientes</h3>
        <button
          class="flex items-center gap-xs px-md py-sm border border-outline-variant rounded-lg text-label-md font-bold text-on-surface-variant hover:bg-surface-container transition-colors"
          :disabled="!summary?.top_clients?.length"
          @click="exportTopClients"
        >
          <span class="material-symbols-outlined !text-sm">download</span>
          Exportar
        </button>
      </div>

      <div v-if="loading" class="p-lg space-y-md">
        <div v-for="i in 5" :key="i" class="flex items-center gap-md">
          <div class="h-4 w-40 rounded bg-surface-container animate-pulse" />
          <div class="h-4 w-16 rounded bg-surface-container animate-pulse" />
          <div class="flex-1" />
          <div class="h-4 w-20 rounded bg-surface-container animate-pulse" />
        </div>
      </div>

      <div v-else-if="!summary?.top_clients?.length" class="p-lg text-center text-on-surface-variant">
        Sin datos de clientes para este mes
      </div>

      <div v-else class="overflow-x-auto">
        <table class="w-full text-left">
          <thead class="bg-surface-container text-on-surface-variant font-label-md uppercase tracking-tighter">
            <tr>
              <th class="px-lg py-md">#</th>
              <th class="px-lg py-md">CLIENTE</th>
              <th class="px-lg py-md text-right">TRANSACCIONES</th>
              <th class="px-lg py-md text-right">TOTAL</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-outline-variant">
            <tr
              v-for="(c, i) in summary.top_clients"
              :key="i"
              class="hover:bg-surface-container-low transition-colors"
            >
              <td class="px-lg py-md text-on-surface-variant">{{ i + 1 }}</td>
              <td class="px-lg py-md font-bold text-on-surface">{{ c.name }}</td>
              <td class="px-lg py-md text-right">{{ formatCount(c.count) }}</td>
              <td class="px-lg py-md text-right font-bold text-on-surface">{{ formatCurrency(c.total) }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>
</template>
