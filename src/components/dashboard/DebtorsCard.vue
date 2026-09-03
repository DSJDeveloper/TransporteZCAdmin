<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import html2pdf from 'html2pdf.js'
import { getDebtorsList, type Debtor } from '@/services/clientService'
import { useAuthStore } from '@/stores/authStore'

const props = defineProps<{
  total?: number
  count?: number
  loading?: boolean
}>()

const auth = useAuthStore()
const exporting = ref(false)
const fetching = ref(false)

// ── Dataset crudo (universo global) obtenido del RPC ─────────────
const rawDebtors = ref<Debtor[]>([])

// ── Rutas autorizadas según rol ───────────────────────────────────
// null = administrador (ve todo); Set de ids = supervisor (solo sus rutas)
const allowedRouteIds = computed<Set<number> | null>(() => {
  if (!auth.isSupervisor) return null
  return new Set(auth.assignedRoutes.map((r) => r.idroute))
})

// ── Fuente única y reactiva de datos para UI y exportación ───────
const filteredDebtors = computed<Debtor[]>(() => {
  const allowed = allowedRouteIds.value
  if (!allowed) return rawDebtors.value
  return rawDebtors.value.filter(
    (d) => d.idroute != null && allowed.has(d.idroute),
  )
})

// ── Indicadores de la tarjeta (estrictamente sobre filteredDebtors) ──
const displayCount = computed(() => filteredDebtors.value.length)
const displayTotal = computed(() =>
  filteredDebtors.value.reduce((acc, d) => acc + (d.balance ?? 0), 0),
)
const displayTickets = computed(() =>
  filteredDebtors.value.reduce((acc, d) => acc + (d.tickets ?? 0), 0),
)
const isLoading = computed(() => props.loading === true || fetching.value)

async function loadDebtors() {
  fetching.value = true
  try {
    if (auth.isSupervisor) {
      await auth.fetchAssignedRoutes()
    }
    rawDebtors.value = await getDebtorsList()
  } catch (err) {
    console.error('Error loading debtors list:', err)
    rawDebtors.value = []
  } finally {
    fetching.value = false
  }
}

onMounted(loadDebtors)

// ── Helpers de formato ────────────────────────────────────────────
function esc(value: string | number | null | undefined): string {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

function debtorName(d: Debtor): string {
  return d.name || d.auth_user_name || '—'
}

function fmtUsd(n: number | null | undefined): string {
  const v = n ?? 0
  const sign = v < 0 ? '-' : ''
  return sign + '$' + Math.abs(v).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function fmtTickets(n: number | null | undefined): string {
  const v = n ?? 0
  const sign = v < 0 ? '-' : ''
  return sign + Math.abs(v).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function fmtCount(n: number): string {
  return n.toLocaleString('en-US')
}

// ── Construcción del PDF (usa la MISMA filteredDebtors) ──────────
interface RouteGroup {
  name: string
  rows: Debtor[]
  ticketsTotal: number
  usdTotal: number
}

function buildGroupHtml(group: RouteGroup): string {
  const rowsHtml = group.rows
    .map(
      (d, i) => `
        <tr class="${i % 2 === 0 ? '' : 'zebra'}">
          <td style="text-align:left;font-weight:600;">${esc(debtorName(d))}</td>
          <td style="text-align:left;color:#64748b;">${esc(d.email) || '—'}</td>
          <td class="num neg" style="color:#dc2626;font-weight:700;">${fmtTickets(d.tickets)}</td>
          <td class="num" style="color:#dc2626;font-weight:700;">${fmtUsd(d.balance)}</td>
        </tr>`,
    )
    .join('')

  return `
    <div class="route-block">
      <div class="route-header">
        <span>RUTA: ${esc(group.name)}</span>
        <span>${fmtCount(group.rows.length)} deudor(es)</span>
      </div>
      <table>
        <thead>
          <tr>
            <th style="text-align:left;">CLIENTE</th>
            <th style="text-align:left;">EMAIL</th>
            <th class="num">TICKETS ADEUDADOS</th>
            <th class="num">SALDO (USD)</th>
          </tr>
        </thead>
        <tbody>${rowsHtml}</tbody>
      </table>
      <div class="route-total">
        <span><strong>${fmtCount(group.rows.length)}</strong> deudor(es) en la ruta</span>
        <span>Tickets: <strong>${fmtTickets(group.ticketsTotal)}</strong></span>
        <span>Saldo: <strong>${fmtUsd(group.usdTotal)}</strong></span>
      </div>
    </div>`
}

async function exportPdf() {
  exporting.value = true
  try {
    // Refresca y re-aplica el mismo filtro por rol
    await loadDebtors()
    const debtors = [...filteredDebtors.value].sort(
      (a, b) => (a.balance ?? 0) - (b.balance ?? 0),
    )

    // Agrupación por ruta
    const map = new Map<string, Debtor[]>()
    for (const d of debtors) {
      const key = d.route_name || 'SIN RUTA'
      const bucket = map.get(key)
      if (bucket) bucket.push(d)
      else map.set(key, [d])
    }

    const groups: RouteGroup[] = [...map.entries()]
      .map(([name, rows]) => ({
        name,
        rows,
        ticketsTotal: rows.reduce((acc, d) => acc + (d.tickets ?? 0), 0),
        usdTotal: rows.reduce((acc, d) => acc + (d.balance ?? 0), 0),
      }))
      .sort((a, b) => a.name.localeCompare(b.name, 'es'))

    const grandTickets = groups.reduce((acc, g) => acc + g.ticketsTotal, 0)
    const grandUsd = groups.reduce((acc, g) => acc + g.usdTotal, 0)
    const grandCount = debtors.length

    const dateLabel = new Date().toLocaleDateString('es-AR', { day: '2-digit', month: 'long', year: 'numeric' })
    const generatedAt = new Date().toLocaleString('es-AR', {
      day: '2-digit',
      month: '2-digit',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    })
    const scopeNote = auth.isSupervisor
      ? `Ámbito: Supervisor — ${auth.assignedRouteCount} ruta(s) asignada(s)`
      : 'Ámbito: Administrador — todas las rutas'

    const bodyHtml =
      debtors.length === 0
        ? `<div style="text-align:center;color:#64748b;padding:24px 0;">No hay deudores en el ámbito del usuario.</div>`
        : groups.map(buildGroupHtml).join('')

    const container = document.createElement('div')
    container.id = 'debtors-report'
    container.style.cssText = 'font-family:Inter,Arial,Helvetica,sans-serif;width:680px;background:#fff;'

    container.innerHTML = `
      <style>
        #debtors-report { color:#1e293b; }
        #debtors-report .doc-header {
          display:flex; justify-content:space-between; align-items:flex-end;
          border-bottom:2px solid #1e293b; padding-bottom:10px; margin-bottom:8px;
        }
        #debtors-report .doc-header h1 { font-size:16pt; font-weight:700; margin:0; color:#1e293b; text-transform:uppercase; }
        #debtors-report .doc-header h2 { font-size:13pt; font-weight:700; margin:4px 0 0 0; color:#1e293b; text-transform:uppercase; }
        #debtors-report .doc-header .meta { font-size:9pt; color:#64748b; margin-top:4px; }
        #debtors-report .doc-header .print { text-align:right; font-size:9pt; color:#475569; }
        #debtors-report .route-block { margin:10px 0 14px 0; page-break-inside:avoid; }
        #debtors-report .route-header {
          display:flex; justify-content:space-between; align-items:center;
          background:#1e293b; color:#fff; padding:6px 10px; font-size:10pt;
          font-weight:700; border-radius:3px;
        }
        #debtors-report table { width:100%; border-collapse:collapse; font-size:10pt; margin-top:4px; }
        #debtors-report thead th {
          background:#f2f2f2; color:#1e293b; font-weight:700; text-align:right;
          padding:6px 10px; border:1px solid #d1d5db;
        }
        #debtors-report tbody td { padding:6px 10px; border:1px solid #d1d5db; text-align:right; color:#334155; }
        #debtors-report tbody tr.zebra { background:#f9f9f9; }
        #debtors-report .num { text-align:right; white-space:nowrap; }
        #debtors-report .route-total {
          display:flex; justify-content:space-between; background:#f8fafc;
          border:1px solid #d1d5db; border-top:0; padding:6px 10px; font-size:10pt; color:#475569;
        }
        #debtors-report .grand-total {
          display:flex; justify-content:space-between; align-items:center;
          background:#fef2f2; border:2px solid #dc2626; border-radius:4px;
          padding:10px 14px; margin-top:6px; page-break-inside:avoid;
        }
        #debtors-report .grand-total .label { font-size:10pt; color:#991b1b; text-transform:uppercase; font-weight:700; }
        #debtors-report .grand-total .amounts { text-align:right; font-size:10pt; color:#991b1b; }
        #debtors-report .grand-total .amounts strong { font-size:11pt; color:#dc2626; }
        #debtors-report .footer-note { margin-top:14px; font-size:8pt; color:#94a3b8; text-align:center; }
      </style>

      <div class="doc-header">
        <div>
          <h1>Transporte ZC</h1>
          <h2>Reporte de Cuentas por Cobrar</h2>
          <div class="meta">Generado el ${esc(dateLabel)} · ${esc(scopeNote)}</div>
        </div>
        <div class="print">
          <strong>Fecha de impresión:</strong><br/>${esc(generatedAt)}
        </div>
      </div>

      ${bodyHtml}

      <div class="grand-total">
        <div class="label">Gran total</div>
        <div class="amounts">
          <div><strong>${fmtCount(grandCount)}</strong> deudor(es)</div>
          <div>Tickets adeudados: <strong>${fmtTickets(grandTickets)}</strong></div>
          <div>Saldo (USD): <strong>${fmtUsd(grandUsd)}</strong></div>
        </div>
      </div>

      <div class="footer-note">Documento generado automáticamente por Transporte ZC.</div>
    `

    document.body.appendChild(container)

    await html2pdf()
      .set({
        margin: [14, 8, 14, 8],
        filename: `Reporte_Deudores_${dateLabel.replace(/\s+/g, '_')}.pdf`,
        image: { type: 'jpeg', quality: 0.98 },
        html2canvas: { scale: 2, useCORS: true, letterRendering: true },
        jsPDF: { unit: 'mm', format: 'a4', orientation: 'portrait' },
        pagebreak: { mode: ['avoid-all', 'css', 'legacy'] },
      })
      .from(container)
      .save()
  } catch (err) {
    console.error('Error exporting debtors PDF:', err)
  } finally {
    document.getElementById('debtors-report')?.remove()
    exporting.value = false
  }
}
</script>

<template>
  <div
    class="p-lg rounded-xl flex flex-col justify-between h-48 transition-all bg-surface-container-lowest border border-outline-variant shadow-sm hover:border-primary relative"
  >
    <template v-if="isLoading">
      <div class="space-y-md">
        <div class="flex justify-between items-start">
          <div class="p-sm rounded-lg bg-surface-container h-10 w-10 animate-pulse" />
          <div class="h-4 w-16 rounded bg-surface-container animate-pulse" />
        </div>
        <div class="space-y-xs">
          <div class="h-3 w-24 rounded bg-surface-container animate-pulse" />
          <div class="h-8 w-32 rounded bg-surface-container animate-pulse" />
        </div>
      </div>
    </template>

    <template v-else>
      <div class="flex justify-between items-start">
        <div class="p-sm rounded-lg bg-error-container/20">
          <span class="material-symbols-outlined text-error">account_balance_wallet</span>
        </div>
        <div class="flex items-center gap-1">
          <span class="font-bold flex items-center text-label-md px-xs py-1 rounded whitespace-nowrap bg-error-container/30 text-error">
            {{ fmtCount(displayCount) }} clientes
          </span>
          <button
            v-if="displayCount > 0"
            class="text-error hover:bg-error-container/20 p-1 rounded-lg transition-colors"
            :disabled="exporting"
            @click="exportPdf"
            title="Exportar PDF"
          >
            <span v-if="exporting" class="material-symbols-outlined !text-md animate-spin">refresh</span>
            <span v-else class="material-symbols-outlined !text-md">picture_as_pdf</span>Generar PDF
          </button>
        </div>
      </div>

      <div>
        <h3 class="font-label-md uppercase tracking-wider text-on-surface-variant">TOTAL DEUDORES</h3>
        <p class="font-headline-lg text-headline-lg text-error">{{ fmtUsd(displayTotal) }}</p>
        <p v-if="displayCount > 0" class="text-body-sm text-on-surface-variant mt-1">
          Tickets adeudados: <strong class="text-error">{{ fmtTickets(displayTickets) }}</strong>
        </p>
      </div>
    </template>
  </div>
</template>
