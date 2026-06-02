<script setup lang="ts">
import { ref, nextTick, onUnmounted } from 'vue'
import { useToast } from 'primevue/usetoast'
import { Html5Qrcode } from 'html5-qrcode'

const props = withDefaults(defineProps<{
  showFileUpload?: boolean
  showManualInput?: boolean
  autoStop?: boolean
  scanButtonLabel?: string
  placeholderLabel?: string
}>(), {
  showFileUpload: true,
  showManualInput: true,
  autoStop: true,
  scanButtonLabel: 'Escanear código QR',
  placeholderLabel: 'Coloque el código QR dentro del marco',
})

const emit = defineEmits<{
  'scan-success': [value: string]
}>()

const toast = useToast()

const isScanning = ref(false)
const showScanner = ref(false)
const scannerError = ref<string | null>(null)
const manualCode = ref('')
const showManualInputField = ref(false)

let html5QrCode: Html5Qrcode | null = null

async function start() {
  if (isScanning.value) return
  try {
    scannerError.value = null
    showScanner.value = true

    await nextTick()

    const el = document.getElementById('qr-reader')
    if (!el) throw new Error('Elemento QR no encontrado')

    html5QrCode = new Html5Qrcode('qr-reader')
    await html5QrCode.start(
      { facingMode: 'environment' },
      { fps: 10, qrbox: { width: 250, height: 250 }, aspectRatio: 1 },
      onScanSuccess,
      () => {},
    )

    isScanning.value = true
  } catch (err: any) {
    const msg = err?.message || ''
    if (msg.includes('NotAllowed') || msg.includes('Permission')) {
      scannerError.value = 'Permiso de cámara denegado. Actívalo desde los ajustes del dispositivo.'
    } else if (msg.includes('NotFound')) {
      scannerError.value = 'No se detectó una cámara en este dispositivo.'
    } else if (msg.includes('NotReadable')) {
      scannerError.value = 'La cámara está siendo usada por otra aplicación.'
    } else {
      scannerError.value = `Error de cámara: ${msg || err}`
    }
    console.error('Scanner error:', err)
  }
}

function stop() {
  if (html5QrCode) {
    html5QrCode.stop().then(() => {
      html5QrCode?.clear()
      html5QrCode = null
    }).catch(() => {})
    isScanning.value = false
    showScanner.value = false
  }
}

async function scanFromFile(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return

  try {
    const codeReader = new Html5Qrcode('qr-reader')
    const decodedText = await codeReader.scanFile(file, false)
    emit('scan-success', decodedText)
    toast.add({ severity: 'success', summary: 'Código leído', detail: 'QR procesado desde la imagen', life: 3000 })
  } catch {
    toast.add({ severity: 'error', summary: 'Error', detail: 'No se pudo leer el código QR de la imagen', life: 3000 })
  }

  input.value = ''
}

function onScanSuccess(decodedText: string) {
  if (props.autoStop) stop()
  emit('scan-success', decodedText)
}

function addManualCode() {
  const code = manualCode.value.trim()
  if (!code) {
    toast.add({ severity: 'warn', summary: 'Campo vacío', detail: 'Ingresa un código válido', life: 3000 })
    return
  }
  manualCode.value = ''
  showManualInputField.value = false
  emit('scan-success', code)
}

defineExpose({ start, stop, isScanning })

onUnmounted(() => {
  stop()
})
</script>

<template>
  <div class="bg-surface-container-low rounded-3xl p-6 flex flex-col items-center text-center shadow-sm border border-outline-variant/30">
    <!-- Scan frame -->
    <div v-show="!showScanner"
      class="w-full aspect-square max-w-[280px] rounded-2xl flex flex-col items-center justify-center bg-surface-container border-2 border-dashed border-outline-variant/50 mb-6 transition-all hover:scale-[1.02]">
      <span class="pi pi-qrcode text-7xl text-primary/40 mb-3" />
      <span class="pi pi-camera text-4xl text-primary animate-pulse" />
      <p class="mt-4 text-label-md text-primary/70">{{ placeholderLabel }}</p>
    </div>

    <!-- Camera preview -->
    <div v-show="showScanner" class="w-full mb-4">
      <div id="qr-reader" class="w-full aspect-square max-w-[280px] mx-auto rounded-2xl overflow-hidden" />
    </div>

    <p v-if="scannerError" class="text-error text-sm mb-4 flex items-center justify-center gap-2">
      <span class="pi pi-exclamation-triangle" />
      {{ scannerError }}
    </p>

    <div class="space-y-4 w-full">
      <button v-if="!isScanning && !scannerError"
        class="w-full bg-primary text-on-primary py-4 px-6 rounded-full text-headline-sm flex items-center justify-center gap-2 hover:brightness-110 transition-all shadow-md active:scale-95"
        @click="start">
        <span class="pi pi-camera" />
        {{ scanButtonLabel }}
      </button>
      <button v-if="isScanning"
        class="w-full bg-error-container text-error py-4 px-6 rounded-full text-headline-sm flex items-center justify-center gap-2 hover:brightness-110 transition-all shadow-md active:scale-95"
        @click="stop">
        <span class="pi pi-stop" />
        Detener Cámara
      </button>
      <button v-if="scannerError && !isScanning"
        class="w-full bg-primary text-on-primary py-4 px-6 rounded-full text-headline-sm flex items-center justify-center gap-2 hover:brightness-110 transition-all shadow-md active:scale-95"
        @click="start">
        <span class="pi pi-refresh" />
        Reintentar
      </button>

      <div class="flex flex-col gap-3">
        <label v-if="showFileUpload"
          class="text-primary text-label-md hover:underline flex items-center justify-center gap-2 cursor-pointer">
          <span class="pi pi-upload text-sm" />
          Escanear archivo de imagen
          <input type="file" accept="image/*" class="hidden" @change="scanFromFile" />
        </label>

        <p v-if="showFileUpload && showManualInput" class="text-[10px] text-outline uppercase tracking-widest font-bold">O</p>

        <button v-if="showManualInput" class="text-on-surface-variant text-label-md hover:text-primary transition-colors"
          @click="showManualInputField = !showManualInputField">
          Ingresar código manualmente
        </button>

        <div v-if="showManualInput && showManualInputField" class="flex gap-2 w-full">
          <input v-model="manualCode" type="text" placeholder="Código del cliente"
            class="flex-1 h-12 px-4 rounded-xl border border-outline-variant bg-surface text-on-surface focus:outline-none focus:border-primary transition-all"
            @keyup.enter="addManualCode" />
          <button
            class="h-12 px-5 bg-primary text-on-primary rounded-xl font-bold hover:brightness-110 transition-all shrink-0"
            @click="addManualCode">
            <span class="pi pi-check" />
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
