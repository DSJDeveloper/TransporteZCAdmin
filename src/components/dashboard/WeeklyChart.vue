<script setup lang="ts">
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import Chart from 'primevue/chart'
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  BarElement,
  Title,
  Tooltip,
  Legend,
} from 'chart.js'

ChartJS.register(CategoryScale, LinearScale, BarElement, Title, Tooltip, Legend)

const router = useRouter()

const props = defineProps<{
  data: { day: string; count: number; total_amount: number }[]
  loading?: boolean
}>()

const dayNames = ['Domingo', 'Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado']

const chartData = computed(() => {
  const labels = props.data.map((d) => {
    const day = d.day
    if (!day) return ''
    const parts = day.split('-')
    if (parts.length === 3) {
      const y = Number(parts[0]) || 0
      const m = (Number(parts[1]) || 1) - 1
      const dd = Number(parts[2]) || 1
      const dt = new Date(y, m, dd)
      const dayName = dayNames[dt.getDay()]
      return dayName || day
    }
    return day
  })
  const counts = props.data.map((d) => d.count)

  return {
    labels,
    datasets: [
      {
        label: 'Transacciones',
        data: counts,
        backgroundColor: '#0050cb',
        borderRadius: 4,
        barThickness: 20,
      },
    ],
  }
})

const chartOptions = {
  indexAxis: 'y' as const,
  responsive: true,
  maintainAspectRatio: false,
  plugins: {
    legend: { display: false },
    tooltip: {
      callbacks: {
        label: (ctx: any) => `${ctx.parsed.x} transacciones`,
      },
    },
  },
  scales: {
    x: {
      beginAtZero: true,
      ticks: { stepSize: 1, font: { size: 11 } },
      grid: { color: '#e5eeff' },
    },
    y: {
      grid: { display: false },
      ticks: { font: { size: 12, weight: '600' as const } },
    },
  },
}
</script>

<template>
  <div class="bg-surface-container-lowest border border-outline-variant rounded-xl p-lg shadow-sm">
    <div class="flex justify-between items-center mb-lg">
      <h3 class="font-headline-sm text-headline-sm text-on-surface">Flujo Semanal</h3>
      <span class="material-symbols-outlined text-outline">bar_chart</span>
    </div>

    <div v-if="loading" class="space-y-md">
      <div v-for="i in 5" :key="i" class="flex items-center gap-md">
        <div class="h-3 w-16 rounded bg-surface-container animate-pulse" />
        <div class="flex-1 h-3 rounded-full bg-surface-container animate-pulse" />
      </div>
    </div>

    <div v-else-if="data.length === 0" class="text-center text-on-surface-variant py-lg">
      Sin datos para esta semana
    </div>

    <div v-else class="h-64">
      <Chart type="bar" :data="chartData" :options="chartOptions" class="h-full" />
    </div>

    <button
      class="w-full mt-lg text-primary font-bold text-label-md hover:underline"
      @click="router.push({ name: 'analisis-mensual' })"
    >
      Reporte de Análisis Completo
    </button>
  </div>
</template>
