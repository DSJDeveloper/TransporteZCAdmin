<script setup lang="ts">
import { ref } from 'vue'

const props = withDefaults(defineProps<{
  title?: string
  modelValue?: File | null
  accept?: string
  hint?: string
  icon?: string
}>(), {
  title: 'Subir archivo',
  accept: 'image/*',
  icon: 'pi pi-camera',
})

const emit = defineEmits<{
  'update:modelValue': [value: File | null]
}>()

const isDragOver = ref(false)
const fileInput = ref<HTMLInputElement | null>(null)
const previewUrl = ref<string | null>(null)

function handleFileChange(event: Event) {
  const input = event.target as HTMLInputElement
  const selectedFile = input.files?.[0]
  if (!selectedFile) return
  emit('update:modelValue', selectedFile)
  if (selectedFile.type.startsWith('image/')) {
    const reader = new FileReader()
    reader.onload = (e) => {
      previewUrl.value = e.target?.result as string
    }
    reader.readAsDataURL(selectedFile)
  }
}

function removeFile() {
  emit('update:modelValue', null)
  previewUrl.value = null
}

function onDragOver(e: DragEvent) {
  e.preventDefault()
  isDragOver.value = true
}

function onDragLeave(e: DragEvent) {
  e.preventDefault()
  isDragOver.value = false
}

function onDrop(e: DragEvent) {
  e.preventDefault()
  isDragOver.value = false
  const droppedFile = e.dataTransfer?.files?.[0]
  if (!droppedFile) return
  emit('update:modelValue', droppedFile)
  if (droppedFile.type.startsWith('image/')) {
    const reader = new FileReader()
    reader.onload = (ev) => {
      previewUrl.value = ev.target?.result as string
    }
    reader.readAsDataURL(droppedFile)
  }
}

function onClick() {
  fileInput.value?.click()
}
</script>

<template>
  <div class="space-y-1">
    <label v-if="title" class="block text-label-md text-on-surface-variant">{{ title }}</label>
    <div
      class="border-2 border-dashed rounded-xl p-6 sm:p-8 flex flex-col items-center justify-center gap-4 cursor-pointer transition-all"
      :class="isDragOver
        ? 'border-primary bg-primary-container/10'
        : 'border-outline-variant bg-surface hover:bg-surface-container'"
      @click="onClick"
      @dragover="onDragOver"
      @dragleave="onDragLeave"
      @drop="onDrop"
    >
      <input
        ref="fileInput"
        :accept="accept"
        type="file"
        class="hidden"
        @change="handleFileChange"
      />
      <div v-if="!modelValue" class="flex flex-col items-center gap-4">
        <div class="w-12 h-12 rounded-full bg-primary-container flex items-center justify-center text-on-primary-container transition-transform group-hover:scale-110">
          <span :class="[icon, 'text-xl']" />
        </div>
        <div class="text-center">
          <p class="text-headline-sm text-on-surface">Subir {{ accept.includes('pdf') ? 'comprobante' : 'fotografía' }}</p>
          <p class="text-on-surface-variant text-body-md mt-1">Haz clic o arrastra la imagen aquí</p>
        </div>
      </div>
      <div v-else class="w-full">
        <img
          v-if="previewUrl"
          :src="previewUrl"
          class="rounded-lg max-h-48 w-full object-cover border border-outline-variant"
          alt="Preview"
        />
        <p v-else class="text-body-md text-on-surface text-center">
          {{ modelValue.name }}
        </p>
        <button class="mt-2 text-error text-label-md flex items-center justify-center w-full" @click.stop="removeFile">
          Eliminar {{ accept.includes('pdf') ? 'archivo' : 'imagen' }}
        </button>
      </div>
    </div>
    <p v-if="hint" class="text-outline text-xs mt-2 italic">{{ hint }}</p>
  </div>
</template>
