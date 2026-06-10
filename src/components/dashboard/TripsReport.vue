<script setup lang="ts">
import { ref } from 'vue'
import { getTripsByDateRange } from '@/services/transactionService'
import { formatDate } from '@/utils/formatters'
import html2pdf from 'html2pdf.js'

const dateFrom = ref<Date>(new Date())
const dateTo = ref<Date>(new Date())
const exporting = ref(false)

async function exportPdf() {
  exporting.value = true
  try {
    const fromStr = dateFrom.value.toISOString().split('T')[0] ?? ''
    const toStr = dateTo.value.toISOString().split('T')[0] ?? ''
    const rows = await getTripsByDateRange(fromStr, toStr)
    const dateLabel = `${fmtDate(dateFrom.value)} — ${fmtDate(dateTo.value)}`

    const container = document.createElement('div')
    container.style.cssText = 'padding:40px 30px;font-family:Inter,Arial,Helvetica,sans-serif;width:680px;'
    container.innerHTML = `
      <div style="display:flex;justify-content:space-between;align-items:flex-end;margin-bottom:6px;">
        <h1 style="font-size:16pt;font-weight:700;margin:0;color:#1e293b;">Listado de Estudiantes que viajaron</h1>
        <span style="font-size:10pt;color:#64748b;">${dateLabel}</span>
      </div>
      <hr style="border:none;border-top:1px solid #cbd5e1;margin:0 0 16px;">
      <table style="width:100%;border-collapse:collapse;font-size:10pt;">
        <thead>
          <tr style="background:#f2f2f2;">
            <th style="padding:8px 12px;border:1px solid #ddd;font-weight:700;text-align:left;color:#1e293b;">FECHA</th>
            <th style="padding:8px 12px;border:1px solid #ddd;font-weight:700;text-align:left;color:#1e293b;">ESTUDIANTE</th>
            <th style="padding:8px 12px;border:1px solid #ddd;font-weight:700;text-align:left;color:#1e293b;">RUTA</th>
            <th style="padding:8px 12px;border:1px solid #ddd;font-weight:700;text-align:left;color:#1e293b;">UNIDAD</th>
          </tr>
        </thead>
        <tbody>
          ${rows.map((r, i) => `
            <tr style="background:${i % 2 === 0 ? '#fff' : '#f9f9f9'};">
              <td style="padding:6px 12px;border:1px solid #ddd;color:#334155;">${formatDate(new Date(r.date))}</td>
              <td style="padding:6px 12px;border:1px solid #ddd;color:#334155;">${r.client_name}</td>
              <td style="padding:6px 12px;border:1px solid #ddd;color:#334155;">${r.route_name ?? ''}</td>
              <td style="padding:6px 12px;border:1px solid #ddd;color:#334155;">${r.unit_name ?? ''}</td>
            </tr>
          `).join('')}
        </tbody>
      </table>
      <div style="display:flex;justify-content:space-between;padding:10px 12px;margin-top:8px;background:#f8fafc;border:1px solid #ddd;font-size:10pt;">
        <span style="color:#475569;">Total de estudiantes: <strong style="color:#1e293b;">${rows.length}</strong></span>
        <span style="color:#475569;">${dateLabel}</span>
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
    console.error('Error exporting PDF:', err)
  } finally {
    exporting.value = false
  }
}

function fmtDate(d: Date): string {
  const day = String(d.getDate()).padStart(2, '0')
  const month = String(d.getMonth() + 1).padStart(2, '0')
  const year = d.getFullYear()
  return `${day}/${month}/${year}`
}
</script>

<template>
  <div class="bg-surface-container-lowest border border-outline-variant rounded-xl overflow-hidden shadow-sm">
    <div class="p-lg border-b border-outline-variant flex items-center justify-between flex-wrap gap-sm">
      <div class="flex items-center gap-md">
        <span class="material-symbols-outlined text-primary">directions_bus</span>
        <h3 class="font-headline-sm text-headline-sm text-on-surface">Reporte de Viajes Realizados</h3>
      </div>
      <div class="flex gap-xs items-center">
        <DatePicker
          v-model="dateFrom"
          dateFormat="dd/mm/yy"
          mask="99/99/9999"
          placeholder="Desde"
          showIcon
          iconDisplay="input"
          class="!w-40"
        />
        <span class="text-outline text-body-md">al</span>
        <DatePicker
          v-model="dateTo"
          dateFormat="dd/mm/yy"
          mask="99/99/9999"
          placeholder="Hasta"
          showIcon
          iconDisplay="input"
          class="!w-40"
        />
        <button
          class="bg-primary text-white px-md py-1 rounded-lg text-label-md font-bold hover:bg-primary/90 transition-colors disabled:opacity-50 flex items-center gap-1"
          :disabled="exporting"
          @click="exportPdf"
        >
          <span v-if="exporting" class="material-symbols-outlined !text-sm animate-spin">refresh</span>
          <span v-else class="material-symbols-outlined !text-sm">picture_as_pdf</span>
          Generar PDF
        </button>
      </div>
    </div>
  </div>
</template>
