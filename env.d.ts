/// <reference types="vite/client" />

declare const __APP_BUILD_HASH__: string

declare module 'html2pdf.js' {
  interface Html2PdfOptions {
    margin?: number | [number, number, number, number]
    filename?: string
    image?: { type?: string; quality?: number }
    html2canvas?: Partial<{
      scale: number
      useCORS: boolean
      letterRendering: boolean
      width: number
      scrollY: number
    }>
    jsPDF?: Partial<{
      unit: string
      format: string
      orientation: 'portrait' | 'landscape'
    }>
    pagebreak?: Partial<{
      mode: string | string[]
      before: string
      after: string
      avoid: string
    }>
  }

  interface Html2PdfInstance {
    set(opt: Html2PdfOptions): Html2PdfInstance
    from(element: HTMLElement | string): Html2PdfInstance
    save(): Promise<void>
    output(type: string, options?: unknown): Promise<unknown>
    toPdf(): Promise<Html2PdfInstance>
    get(key: string): Promise<unknown>
  }

  export default function html2pdf(): Html2PdfInstance
}
