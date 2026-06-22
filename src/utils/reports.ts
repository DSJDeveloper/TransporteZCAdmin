import html2pdf from "html2pdf.js";
import { formatDateShort } from "./formatters";

/**
 * Genera un encabezado estándar para reportes.
 * @param title - Título del reporte.
 * @param dateLabel - Rango de fechas del reporte (opcional).
 */
export function getHeaderReports(title: string, dateLabel?: string): string {
  const fechaImpresion = formatDateShort(new Date());

  // El periodo solo aparece si existe
  const dateDisplay = dateLabel
    ? `<div style="font-size: 10pt; color: #64748b; margin-top: 2px;">Periodo: ${dateLabel}</div>`
    : "";

  return `
  <div style="border-bottom: 2px solid #1e293b; padding-bottom: 10px; margin-bottom: 20px;">
    <div style="display: flex; justify-content: space-between; align-items: flex-start;">
      <div style="display: flex; flex-direction: column;">
        <h1 style="font-size: 14pt; margin: 0; color: #1e293b; text-transform: uppercase;">Transporte ZC</h1>
        <h2 style="font-size: 12pt; font-weight: 700; margin: 5px 0 0 0; color: #1e293b;">${title}</h2>
        ${dateDisplay}
      </div>
      
      <div style="text-align: right; font-size: 9pt; color: #475569;">
        <strong>Fecha de impresión:</strong> ${fechaImpresion}
      </div>
    </div>
  </div>`;
}
export async function generatePdf(
  container: HTMLDivElement,
  title: string,
  dateLabel?: string,
) {
  document.body.appendChild(container);

  const worker = html2pdf()
    .set({
      margin: [32, 10, 15, 10],
      image: { type: "jpeg", quality: 0.98 },
      html2canvas: { scale: 2, useCORS: true, letterRendering: true },
      jsPDF: { unit: "mm", format: "a4", orientation: "portrait" },
    })
    .from(container);
  await worker.toPdf();
  const pdf = (await worker.get("pdf")) as any;
  //   const totalPages = pdf.internal.getNumberOfPages();

  //   for (let i = 1; i <= totalPages; i++) {
  //     pdf.setPage(i);
  //     pdf.setFontSize(8);
  //     const width = pdf.internal.pageSize.getWidth();
  //     pdf.text(`Página ${i} de ${totalPages}`, width / 2, 5, { align: "center" });
  //   }
  // 1. Asegúrate de tener una función que genere el header en PDF
  function drawHeader(pdf: any, pageNumber: number, totalPages: number) {
  pdf.setPage(pageNumber);
  
  // 1. Título principal
  pdf.setFontSize(14);
  pdf.text("Transporte ZC", 10, 10);
  
  // 2. Subtítulo (Título del reporte)
  pdf.setFontSize(10);
  pdf.text(title, 10, 16);
  
  // 3. Periodo (Aparece debajo del título, ajustando la posición Y)
  // Usamos 21mm para el periodo, lo que lo coloca justo debajo del título
  if (dateLabel) {
    pdf.setFontSize(9);
    pdf.setTextColor(100); // Color gris para diferenciarlo
    pdf.text(`Periodo: ${dateLabel}`, 10, 21);
  }

  // 4. Línea divisoria (La bajamos un poco para que no se superponga al periodo)
  // Ahora comienza en 24mm
  pdf.line(10, 24, 200, 24);

  // 5. Paginación en el pie de página
  pdf.setFontSize(8);
  pdf.setTextColor(0);
  pdf.text(`Página ${pageNumber} de ${totalPages}`, 105, 290, {
    align: "center",
  });
}

  // 2. En tu función generatePdf, después de generar el PDF:
  const totalPages = pdf.internal.getNumberOfPages();
  for (let i = 1; i <= totalPages; i++) {
    drawHeader(pdf, i, totalPages);
  }
  document.body.removeChild(container);
  const blobUrl = pdf.output("bloburl");
  window.open(blobUrl, "_blank");
}
