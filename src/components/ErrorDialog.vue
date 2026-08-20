<script setup lang="ts">
defineProps<{
  visible: boolean
  title?: string
  message: string
  details?: string | null
}>()

const emit = defineEmits<{
  close: []
}>()
</script>

<template>
  <Teleport to="body">
    <div v-if="visible" class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div class="absolute inset-0 bg-black/40 backdrop-blur-sm" @click="emit('close')"></div>
      <div class="relative bg-surface-container-lowest rounded-2xl shadow-2xl border border-outline-variant w-full max-w-md mx-auto p-6 md:p-8 flex flex-col gap-6">
        <div class="flex flex-col items-center gap-4 text-center">
          <div class="w-14 h-14 rounded-full bg-error-container/30 flex items-center justify-center">
            <span class="material-symbols-outlined text-[32px] text-error">error</span>
          </div>
          <h3 class="text-xl font-bold text-on-surface">{{ title ?? 'Error' }}</h3>
          <p class="text-on-surface-variant leading-relaxed">{{ message }}</p>
          <p v-if="details" class="text-sm text-outline bg-surface-container rounded-xl p-3 w-full break-words text-left leading-relaxed">{{ details }}</p>
        </div>
        <button
          class="h-11 w-full rounded-xl bg-primary text-on-primary font-semibold hover:shadow-lg active:scale-[0.98] transition-all"
          @click="emit('close')"
        >
          Cerrar
        </button>
      </div>
    </div>
  </Teleport>
</template>
