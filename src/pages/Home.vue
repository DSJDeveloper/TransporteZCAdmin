<script setup lang="ts">
import { ref, onMounted, nextTick } from 'vue'
import { useRouter } from 'vue-router'
import { supabase } from '@/services/supabaseClient'
import StatCard from '@/components/dashboard/StatCard.vue'
import ReservasTable from '@/components/dashboard/ReservasTable.vue'
import WeeklyChart from '@/components/dashboard/WeeklyChart.vue'
import RecentMovements from '@/components/dashboard/RecentMovements.vue'
import ReservaDetailDialog from '@/components/dashboard/ReservaDetailDialog.vue'

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
const reservasDate = ref(new Date().toISOString().split('T')[0])

const router = useRouter()

const reservasRef = ref<InstanceType<typeof ReservasTable> | null>(null)
const movementsRef = ref<InstanceType<typeof RecentMovements> | null>(null)
const detailDialogRef = ref<InstanceType<typeof ReservaDetailDialog> | null>(null)

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

function onViewDetail(shedule: string, date: string) {
  detailDialogRef.value?.open(shedule, date)
}

onMounted(async () => {
  await loadDashboard()
  await nextTick()
  reservasRef.value?.load()
  movementsRef.value?.load()
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
      <StatCard
        :loading="loading"
        label="TOTAL DEUDORES"
        :value="formatCurrency(kpis?.debtors_total ?? 0)"
        :trend="kpis ? formatCount(kpis.debtors_count) + ' clientes' : undefined"
        icon="account_balance_wallet"
        color="error"
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

    <!-- Reservas Diarias -->
    <ReservasTable
      ref="reservasRef"
      v-model:date="reservasDate"
      @view-detail="onViewDetail"
    />

    <!-- Bottom Section: Weekly Chart + Recent Movements -->
    <div class="grid grid-cols-1 lg:grid-cols-4 gap-lg">
      <WeeklyChart
        :data="weekly"
        :loading="loading"
      />
      <RecentMovements
        ref="movementsRef"
        :limit="5"
      />
    </div>

    <ReservaDetailDialog ref="detailDialogRef" />
  </div>
</template>
