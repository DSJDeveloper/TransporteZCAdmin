<script setup lang="ts">
import { ref, computed, watch } from "vue"
import type { Recharge } from "../services/rechargeService"
import { formatDate, formatDateTime, formatCurrency } from "../utils/formatters"
import { useCompanyStore } from "../stores/companyStore"

const props = withDefaults(defineProps<{
  visible: boolean
  recharge: Recharge | null
  showActions?: boolean
}>(), {
  showActions: true,
})

const emit = defineEmits<{
  "update:visible": [value: boolean]
  approve: [recharge: Recharge]
  reject: [recharge: Recharge]
}>()

const companyStore = useCompanyStore()

function round2(n: number): number {
  return Math.round(n * 100) / 100
}

const ticketsAcreditar = computed<number | null>(() => {
  const r = props.recharge
  if (!r) return null
  const stopPrice = r.stop?.price
  if (stopPrice && stopPrice > 0) return round2(r.amount / stopPrice)
  if (r.tickets != null && r.tickets > 0) return r.tickets
  const global = companyStore.company?.ticket
  if (global && global > 0) return round2(r.amount / global)
  return null
})

function formatTickets(n: number | null): string {
  if (n == null) return "—"
  return Number.isInteger(n) ? String(n) : n.toFixed(2)
}

const previewImage = ref<string | null>(null)
const previewPdf = ref<string | null>(null)
const imgError = ref(false)
const previewImgError = ref(false)

watch(() => props.visible, (v) => {
  if (!v) {
    previewImage.value = null
    previewPdf.value = null
    imgError.value = false
  } else if (!companyStore.company) {
    companyStore.fetchCompany()
  }
})

function close() {
  emit("update:visible", false)
}

function initials(name: string): string {
  return name
    .split(" ")
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w.charAt(0).toUpperCase())
    .join("")
}

function statusLabel(s: number): string {
  if (s === 0) return "PENDIENTE"
  if (s === 1) return "APROBADA"
  return "RECHAZADA"
}

function statusClass(s: number): string {
  if (s === 0) return "bg-amber-100 text-amber-800"
  if (s === 1) return "bg-tertiary-container/20 text-tertiary-container"
  return "bg-error-container text-on-error-container"
}

function canAct(s: number): boolean {
  return s === 0
}

function getMethodLabel(m: string): string {
  const map: Record<string, string> = {
    efectivo: "Efectivo $",
    pago_movil: "Pago Movil",
    "pago móvil": "Pago Movil",
    pago_móvil: "Pago Movil",
  }
  return map[m.toLowerCase()] ?? m
}

function fmtDateTime(d: string | null | undefined): string {
  if (!d) return "—"
  return formatDateTime(d)
}

function isPdf(url: string): boolean {
  return url.toLowerCase().endsWith(".pdf")
}

function openImagePreview(pic: string) {
  previewImage.value = pic
  previewImgError.value = false
}

function openPdfPreview(pic: string) {
  previewPdf.value = pic
}

function onImgError() {
  imgError.value = true
}

function onPreviewImgError() {
  previewImgError.value = true
}
</script>

<template>
  <!-- Detail Modal -->
  <Teleport to="body">
    <div v-if="visible && recharge" class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" @click="close"></div>
      <div class="relative w-full max-w-3xl mx-auto max-h-[90vh] flex flex-col" @click.stop>
        <div
          class="bg-surface-container-lowest rounded-xl shadow-2xl border border-outline-variant overflow-hidden flex flex-col max-h-[90vh]">
          <!-- Header -->
          <div class="flex items-center justify-between p-md md:p-lg border-b border-outline-variant shrink-0">
            <div class="flex items-center gap-md">
              <div class="w-10 h-10 rounded-full bg-primary/10 flex items-center justify-center text-primary">
                <span class="material-symbols-outlined">receipt_long</span>
              </div>
              <div>
                <h3 class="font-headline-sm text-headline-sm text-on-surface">Detalle de Recarga #{{ recharge.id }}</h3>
                <p class="text-label-md text-on-surface-variant">{{ fmtDateTime(recharge.createAt) }}</p>
              </div>
            </div>
            <button class="text-outline hover:text-on-surface transition-colors" @click="close">
              <span class="material-symbols-outlined">close</span>
            </button>
          </div>

          <!-- Body -->
          <div class="overflow-y-auto p-md md:p-lg space-y-lg">
            <!-- Info grid -->
            <div class="grid grid-cols-1 md:grid-cols-2 gap-lg">
              <div class="space-y-md">
                <div>
                  <label
                    class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Cliente</label>
                  <div class="flex items-center gap-sm">
                    <div
                      class="w-9 h-9 rounded-full bg-secondary-container flex items-center justify-center text-secondary font-bold text-[12px] shrink-0">
                      {{ recharge.clients ? initials(recharge.clients.name) : "??" }}
                    </div>
                    <span class="font-bold text-on-surface text-body-md">{{ recharge.clients?.name ?? "—" }}</span>
                  </div>
                </div>
                <div v-if="recharge.route">
                  <label
                    class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Ruta</label>
                  <div class="flex items-center gap-sm">
                    <span class="material-symbols-outlined text-outline">route</span>
                    <span class="text-on-surface font-medium">{{ recharge.route.name }}</span>
                    <span v-if="recharge.route.code" class="text-label-sm text-outline">({{ recharge.route.code }})</span>
                  </div>
                </div>
                <div>
                  <label
                    class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Parada</label>
                  <div v-if="recharge.stop" class="flex items-center gap-sm">
                    <span class="material-symbols-outlined text-outline">pin_drop</span>
                    <span class="text-on-surface font-medium">{{ recharge.stop.name }}</span>
                    <span v-if="recharge.stop.price > 0" class="text-label-sm text-outline">{{ formatCurrency(recharge.stop.price) }}</span>
                  </div>
                  <div v-else class="flex items-center gap-sm">
                    <span class="material-symbols-outlined text-outline">pin_drop</span>
                    <span class="text-outline-variant italic">No asignada</span>
                  </div>
                </div>
                <div>
                  <label
                    class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Método
                    de Pago</label>
                  <div class="flex items-center gap-sm">
                    <span class="material-symbols-outlined text-outline">
                      {{ recharge.method.toLowerCase().includes("efectivo") ? "payments" : "phone_android" }}
                    </span>
                    <span class="text-on-surface font-medium">{{ getMethodLabel(recharge.method) }}</span>
                  </div>
                </div>
                <div v-if="recharge.ref">
                  <label
                    class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Referencia</label>
                  <div class="flex items-center gap-sm">
                    <span class="material-symbols-outlined text-outline">tag</span>
                    <code class="bg-surface-container-high px-sm py-xs rounded text-primary font-bold text-body-md">{{
                      recharge.ref }}</code>
                  </div>
                </div>
                <!-- <div>
                  <label
                    class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Registrado
                    por</label>
                  <div class="flex items-center gap-sm">
                    <span class="material-symbols-outlined text-outline">person</span>
                    <span class="text-on-surface">{{ recharge.createBy ?? "—" }}</span>
                  </div>
                </div> -->
              </div>
              <div class="space-y-md">
                <div>
                  <label
                    class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Monto</label>
                  <div class="text-[28px] font-bold text-on-surface">
                    {{ formatCurrency(recharge.amount) }}
                    <span class="text-body-md text-outline font-normal">USD</span>
                  </div>
                </div>
                <div class="border-t border-outline-variant pt-lg">
                  <label class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Tickets a Recibir</label>
                  <div class="flex items-center gap-sm">
                    <span class="material-symbols-outlined text-outline">confirmation_number</span>
                    <span v-if="ticketsAcreditar != null"
                      class="px-md py-xs rounded-full bg-tertiary-container/20 text-tertiary font-bold text-[15px]">
                      +{{ formatTickets(ticketsAcreditar) }} ticket(s)
                    </span>
                    <span v-else class="text-outline-variant italic">—</span>
                  </div>
                  <p class="text-label-md text-on-surface-variant mt-xs">
                    <template v-if="recharge.stop?.price && recharge.stop.price > 0">
                      Base: {{ formatCurrency(recharge.stop?.price) }} por pasaje en {{ recharge.stop?.name ?? "—" }}
                    </template>
                    <template v-else-if="companyStore.company?.ticket && companyStore.company.ticket > 0">
                      Base global: {{ formatCurrency(companyStore.company?.ticket) }} por pasaje
                    </template>
                    <template v-else>Sin tarifa de referencia</template>
                  </p>
                </div>
                <div v-if="recharge.tasa && recharge.tasa > 0">
                  <label
                    class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Tasa
                    de Cambio</label>
                  <div class="flex items-center gap-sm">
                    <span class="material-symbols-outlined text-outline">currency_exchange</span>
                    <span class="text-on-surface font-bold text-body-md">1 USD = {{
                      formatCurrency(recharge.tasa, 'es-VE', 'VES') }}</span>
                  </div>
                </div>
                <div>
                  <label
                    class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Fecha</label>
                  <div class="flex items-center gap-sm">
                    <span class="material-symbols-outlined text-outline">calendar_today</span>
                    <span class="text-on-surface">{{ formatDate(recharge.date) }}</span>
                  </div>
                </div>
                <div>
                  <label
                    class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Estado</label>
                  <span class="px-md py-sm rounded-full text-[12px] font-bold uppercase tracking-wider inline-block"
                    :class="statusClass(recharge.status)">{{ statusLabel(recharge.status) }}</span>
                </div>
                <div v-if="recharge.status !== 0 && recharge.updateAprobate">
                  <label
                    class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-base">Procesado
                    el</label>
                  <div class="flex items-center gap-sm">
                    <span class="material-symbols-outlined text-outline">check_circle</span>
                    <span class="text-on-surface">{{ fmtDateTime(recharge.updateAprobate) }}</span>
                  </div>
                </div>
              </div>
            </div>

            <!-- Comprobante -->
            <div v-if="recharge.picture" class="border-t border-outline-variant pt-lg">
              <label
                class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-md">Comprobante
                de Pago</label>
              <div
                class="bg-surface-container-low/50 rounded-xl border border-outline-variant overflow-hidden cursor-pointer hover:bg-surface-container-low transition-colors"
                @click="isPdf(recharge.picture!) ? openPdfPreview(recharge.picture!) : openImagePreview(recharge.picture!)">
                <div v-if="isPdf(recharge.picture!)"
                  class="flex flex-col items-center justify-center py-xl text-center">
                  <span class="material-symbols-outlined text-[64px] text-error">picture_as_pdf</span>
                  <span class="text-on-surface-variant text-body-md mt-sm">Ver PDF del comprobante</span>
                  <span class="text-label-md text-primary font-bold mt-xs">Abrir documento →</span>
                </div>
                <img v-else v-show="!imgError" :src="recharge.picture" alt="Comprobante de pago"
                  class="w-full max-h-64 object-contain bg-white" @error="onImgError" />
                <div v-if="imgError"
                  class="flex flex-col items-center justify-center py-xl text-center bg-surface-container-low/50 rounded-xl border border-dashed border-outline-variant">
                  <span class="material-symbols-outlined text-[48px] text-error">broken_image</span>
                  <span class="text-on-surface-variant text-body-md mt-sm">No se pudo cargar la imagen</span>
                  <span class="text-label-md text-outline mt-xs">El comprobante no está disponible</span>
                </div>
              </div>
            </div>
            <div v-else class="border-t border-outline-variant pt-lg">
              <label
                class="block font-label-md text-label-md text-on-surface-variant uppercase tracking-wider mb-md">Comprobante
                de Pago</label>
              <div
                class="flex flex-col items-center justify-center py-xl text-center bg-surface-container-low/50 rounded-xl border border-dashed border-outline-variant">
                <span class="material-symbols-outlined text-[48px] text-outline-variant">image_not_supported</span>
                <span class="text-on-surface-variant text-body-md mt-sm">Sin comprobante adjunto</span>
              </div>
            </div>
          </div>

          <!-- Footer actions -->
          <div v-if="showActions && canAct(recharge.status)"
            class="border-t border-outline-variant p-md md:p-lg flex flex-col-reverse sm:flex-row justify-end gap-md shrink-0 bg-surface-container-low/20">
            <button
              class="h-11 px-lg rounded-xl border border-outline-variant text-on-surface-variant font-bold hover:bg-surface-container transition-all"
              @click="close">Cerrar</button>
            <button
              class="h-11 px-lg rounded-xl bg-error text-on-error font-bold hover:shadow-lg active:scale-[0.98] transition-all flex items-center justify-center gap-xs"
              @click="emit('reject', recharge)">
              <span class="material-symbols-outlined text-[18px]">do_not_disturb_on</span>
              Rechazar
            </button>
            <button
              class="h-11 px-lg rounded-xl bg-tertiary text-on-tertiary font-bold hover:shadow-lg active:scale-[0.98] transition-all flex items-center justify-center gap-xs"
              @click="emit('approve', recharge)">
              <span class="material-symbols-outlined text-[18px]">check_circle</span>
              Aprobar
            </button>
          </div>
          <div v-else
            class="border-t border-outline-variant p-md md:p-lg flex justify-end shrink-0 bg-surface-container-low/20">
            <button
              class="h-11 px-lg rounded-xl border border-outline-variant text-on-surface-variant font-bold hover:bg-surface-container transition-all"
              @click="close">Cerrar</button>
          </div>
        </div>
      </div>
    </div>
  </Teleport>

  <!-- Image Preview Overlay -->
  <Teleport to="body">
    <div v-if="previewImage" class="fixed inset-0 z-[60] flex items-center justify-center p-4"
      @click="previewImage = null">
      <div class="absolute inset-0 bg-black/80 backdrop-blur-sm"></div>
      <div class="relative max-w-4xl max-h-[90vh] w-full mx-auto flex items-center justify-center" @click.stop>
        <button class="absolute -top-10 right-0 text-white/80 hover:text-white transition-colors"
          @click="previewImage = null">
          <span class="material-symbols-outlined text-[28px]">close</span>
        </button>
        <img v-show="!previewImgError" :src="previewImage" alt="Comprobante de pago"
          class="w-full max-h-[85vh] object-contain rounded-xl" @error="onPreviewImgError" />
        <div v-if="previewImgError"
          class="flex flex-col items-center justify-center py-16 text-center">
          <span class="material-symbols-outlined text-[64px] text-error">broken_image</span>
          <span class="text-white text-body-lg mt-sm">No se pudo cargar la imagen</span>
          <span class="text-white/60 text-label-md mt-xs">El comprobante no está disponible</span>
        </div>
      </div>
    </div>
  </Teleport>

  <!-- PDF Preview Overlay -->
  <Teleport to="body">
    <div v-if="previewPdf" class="fixed inset-0 z-[60] flex items-center justify-center p-4"
      @click="previewPdf = null">
      <div class="absolute inset-0 bg-black/80 backdrop-blur-sm"></div>
      <div class="relative w-full max-w-4xl max-h-[90vh] mx-auto flex flex-col" @click.stop>
        <div class="flex items-center justify-between mb-md">
          <span class="text-white font-bold">Comprobante PDF</span>
          <button class="text-white/80 hover:text-white transition-colors" @click="previewPdf = null">
            <span class="material-symbols-outlined text-[28px]">close</span>
          </button>
        </div>
        <iframe :src="previewPdf" class="w-full h-[80vh] rounded-xl bg-white"></iframe>
      </div>
    </div>
  </Teleport>
</template>
