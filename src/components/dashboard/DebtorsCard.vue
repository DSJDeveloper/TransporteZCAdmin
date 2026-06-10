<script setup lang="ts">
import { ref } from 'vue'
import { getDebtorsList, type Debtor } from '@/services/clientService'
import html2pdf from 'html2pdf.js'

const props = defineProps<{
  total: number
  count: number
  loading?: boolean
}>()

const exporting = ref(false)
const pdfRows = ref<Debtor[]>([])

function formatCurrency(n: number): string {
  const sign = n < 0 ? '-' : ''
  return sign + '$' + Math.abs(n).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function formatCount(n: number): string {
  return n.toLocaleString('en-US')
}

async function exportPdf() {
  exporting.value = true
  try {
    pdfRows.value = await getDebtorsList()

    const totalBalance = pdfRows.value.reduce((sum, d) => sum + d.balance, 0)
    const dateLabel = new Date().toLocaleDateString('es-AR', { day: '2-digit', month: 'long', year: 'numeric' })

    const container = document.createElement('div')
    container.style.cssText = 'padding:40px 30px;font-family:Inter,Arial,Helvetica,sans-serif;width:680px;'
    container.innerHTML = `
      <div style="display:flex;justify-content:space-between;align-items:flex-end;margin-bottom:6px;">
        <h1 style="font-size:16pt;font-weight:700;margin:0;color:#1e293b;">Reporte de Cuentas por Cobrar</h1>
        <span style="font-size:10pt;color:#64748b;">${dateLabel}</span>
      </div>
      <hr style="border:none;border-top:1px solid #cbd5e1;margin:0 0 16px;">
      <table style="width:100%;border-collapse:collapse;font-size:10pt;">
        <thead>
          <tr style="background:#f2f2f2;">
            <th style="padding:8px 12px;border:1px solid #ddd;font-weight:700;text-align:left;color:#1e293b;">NOMBRE ESTUDIANTE</th>
            <th style="padding:8px 12px;border:1px solid #ddd;font-weight:700;text-align:left;color:#1e293b;">CÉDULA</th>
            <th style="padding:8px 12px;border:1px solid #ddd;font-weight:700;text-align:right;color:#1e293b;">SALDO</th>
          </tr>
        </thead>
        <tbody>
          ${pdfRows.value.map((d, i) => `
            <tr style="background:${i % 2 === 0 ? '#fff' : '#f9f9f9'};">
              <td style="padding:6px 12px;border:1px solid #ddd;color:#334155;">${d.name}</td>
              <td style="padding:6px 12px;border:1px solid #ddd;color:#334155;">${d.documentID ?? ''}</td>
              <td style="padding:6px 12px;border:1px solid #ddd;text-align:right;color:#dc2626;font-weight:600;">${formatCurrency(d.balance)}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
      <div style="display:flex;justify-content:space-between;padding:10px 12px;margin-top:8px;background:#f8fafc;border:1px solid #ddd;font-size:10pt;">
        <span style="color:#475569;">Total deudores: <strong style="color:#1e293b;">${pdfRows.value.length}</strong></span>
        <span style="color:#475569;">Total saldo: <strong style="color:#dc2626;">${formatCurrency(totalBalance)}</strong></span>
      </div>
    `

    document.body.appendChild(container)
    const worker = html2pdf().set({
      margin: [15, 10, 15, 10],
      image: { type: 'jpeg', quality: 0.98 },
      html2canvas: { scale: 2, useCORS: true, letterRendering: true },
      jsPDF: { unit: 'mm', format: 'a4', orientation: 'portrait' },
    }).from(container)
    await worker.toPdf()
    const pdf = await worker.get('pdf') as any
    const totalPages = pdf.internal.getNumberOfPages()
    for (let i = 1; i <= totalPages; i++) {
      pdf.setPage(i)
      pdf.setFontSize(8)
      const width = pdf.internal.pageSize.getWidth()
      pdf.text(`Página ${i} de ${totalPages}`, width / 2, 5, { align: 'center' })
    }
    const blobUrl = pdf.output('bloburl')
    window.open(blobUrl, '_blank')
    document.body.removeChild(container)
  } catch (err) {
    console.error('Error exporting debtors PDF:', err)
  } finally {
    pdfRows.value = []
    exporting.value = false
  }
}
</script>

<template>
  <div
    class="p-lg rounded-xl flex flex-col justify-between h-48 transition-all bg-surface-container-lowest border border-outline-variant shadow-sm hover:border-primary relative"
  >
    <template v-if="loading">
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
            {{ formatCount(count) }} clientes
          </span>
          <button
            v-if="count > 0"
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
        <p class="font-headline-lg text-headline-lg text-error">{{ formatCurrency(total) }}</p>
      </div>
    </template>
  </div>
</template>
