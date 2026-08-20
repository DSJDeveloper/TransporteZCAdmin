<script setup lang="ts">
import { ref, onMounted, nextTick } from 'vue'
import { supabase } from '@/services/supabaseClient'
import StatCard from '@/components/dashboard/StatCard.vue'
import DebtorsCard from '@/components/dashboard/DebtorsCard.vue'
import WeeklyChart from '@/components/dashboard/WeeklyChart.vue'
import RecentMovements from '@/components/dashboard/RecentMovements.vue'
import SolicitudesReport from '@/components/dashboard/SolicitudesReport.vue'
import TripsReport from '@/components/dashboard/TripsReport.vue'

interface Kpis {
  debtors_total: number
  debtors_count: number
  active_clients: number
  total_clients: number
  recharges_today: number
  recharges_amount_today: number
  transactions_today: number
}

interface WeekRow {
  day: string
  count: number
  total_amount: number
}

const kpis = ref<Kpis | null>(null)
const weekly = ref<WeekRow[]>([])
const loading = ref(true)
const ready = ref(false)

const movementsRef = ref<InstanceType<typeof RecentMovements> | null>(null)
const tripsReportRef = ref<InstanceType<typeof TripsReport> | null>(null)

function formatCurrency(n: number): string {
  const sign = n < 0 ? '-' : ''
  return sign + '$' + Math.abs(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function formatCount(n: number): string {
  return n.toLocaleString('en-US')
}

async function loadDashboard() {
  loading.value = true
  try {
    const [kpiRes, weeklyRes] = await Promise.all([
      supabase.rpc('get_dashboard_kpis'),
      supabase.rpc('get_weekly_flow'),
    ])
    if (kpiRes.data) kpis.value = kpiRes.data as Kpis
    if (weeklyRes.data) weekly.value = weeklyRes.data as WeekRow[]
  } catch (err) {
    console.error('Dashboard load error:', err)
  } finally {
    loading.value = false
  }
}

onMounted(async () => {
  // 1. Allow browser to paint initial layout with skeletons
  await nextTick()
  ready.value = true
  // 2. Defer data loading to end of microtask queue
  await nextTick()
  await loadDashboard()
  // 3. Load child data after parent is settled
  movementsRef.value?.load()
  tripsReportRef.value?.load()
})
</script>

<template>
  <div class="p-margin-desktop space-y-xl">
    <!-- Header -->
    <div class="flex items-center justify-between">
      <div>
        <h2 class="font-headline-lg text-headline-lg text-on-surface">Panel de Operaciones</h2>
        <p class="font-body-lg text-body-lg text-on-surface-variant">Monitoreo en tiempo real de flota y finanzas</p>
      </div>
    </div>

    <!-- KPI Cards -->
    <div class="grid grid-cols-1 md:grid-cols-4 gap-lg">
      <DebtorsCard
        :loading="loading"
        :total="kpis?.debtors_total ?? 0"
        :count="kpis?.debtors_count ?? 0"
      />
      <StatCard
        :loading="loading"
        label="CLIENTES ACTIVOS"
        :value="formatCount(kpis?.active_clients ?? 0)"
        :trend="kpis ? formatCount(kpis.total_clients) + ' total' : undefined"
        trend-up
        icon="group"
        color="primary"
        :subtitle="kpis ? 'de ' + formatCount(kpis.total_clients) + ' registrados' : undefined"
      />
      <StatCard
        :loading="loading"
        label="TRANSACCIONES HOY"
        :value="formatCount(kpis?.transactions_today ?? 0)"
        icon="swap_horiz"
        color="tertiary"
      />
      <StatCard
        :loading="loading"
        label="RECAUDACIÓN HOY"
        :value="formatCurrency(kpis?.recharges_amount_today ?? 0)"
        :trend="kpis ? formatCount(kpis.recharges_today) + ' recargas' : undefined"
        trend-up
        icon="payments"
        :subtitle="kpis ? formatCount(kpis.recharges_today) + ' recargas' : undefined"
        accent
      />
    </div>

    <!-- Skeleton: Reportes -->
    <div v-if="!ready" class="bg-surface-container-lowest border border-outline-variant rounded-xl overflow-hidden shadow-sm">
      <div class="p-lg border-b border-outline-variant">
        <div class="h-5 w-56 bg-surface-container-high rounded animate-pulse" />
      </div>
    </div>
    <SolicitudesReport v-if="ready" />

    <div v-if="!ready" class="bg-surface-container-lowest border border-outline-variant rounded-xl overflow-hidden shadow-sm">
      <div class="p-lg border-b border-outline-variant">
        <div class="h-5 w-56 bg-surface-container-high rounded animate-pulse" />
      </div>
    </div>
    <TripsReport v-if="ready" ref="tripsReportRef" />

    <!-- Bottom Section: Weekly Chart + Recent Movements -->
    <div class="grid grid-cols-1 lg:grid-cols-4 gap-lg">
      <WeeklyChart
        :data="weekly"
        :loading="loading"
      />
      <div v-if="!ready" class="lg:col-span-3 bg-surface-container-lowest border border-outline-variant rounded-xl p-lg shadow-sm">
        <div class="space-y-gutter">
          <div v-for="i in 3" :key="i" class="flex items-center gap-md p-md">
            <div class="w-12 h-12 rounded-full bg-surface-container animate-pulse shrink-0" />
            <div class="flex-1 space-y-xs">
              <div class="h-4 w-48 rounded bg-surface-container animate-pulse" />
              <div class="h-3 w-32 rounded bg-surface-container animate-pulse" />
            </div>
            <div class="text-right space-y-xs">
              <div class="h-4 w-20 rounded bg-surface-container animate-pulse" />
              <div class="h-3 w-24 rounded bg-surface-container animate-pulse" />
            </div>
          </div>
        </div>
      </div>
      <RecentMovements
        v-if="ready"
        ref="movementsRef"
        :limit="5"
      />
    </div>
  </div>
</template>
