<script setup lang="ts">
defineProps<{
  visible: boolean
  title: string
  message: string
  confirmLabel?: string
  loading?: boolean
  icon?: string
  variant?: "danger" | "primary"
}>()

const emit = defineEmits<{
  confirm: []
  cancel: []
}>()
</script>

<template>
  <Teleport to="body">
    <div v-if="visible" class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div class="absolute inset-0 bg-black/40 backdrop-blur-sm" @click="emit('cancel')"></div>
      
      <div class="relative bg-surface-container-lowest rounded-2xl shadow-2xl border border-outline-variant w-full max-w-lg mx-auto p-6 md:p-8 flex flex-col gap-6">
        
        <div class="flex items-start gap-4">
          <div
            class="w-12 h-12 rounded-full flex items-center justify-center shrink-0"
            :class="variant === 'danger' ? 'bg-error-container/30' : 'bg-primary-container/30'"
          >
            <span
              class="material-symbols-outlined text-[28px]"
              :class="variant === 'danger' ? 'text-error' : 'text-primary'"
            >
              {{ icon ?? (variant === 'danger' ? 'warning' : 'help_outline') }}
            </span>
          </div>
          
          <div class="flex-1 min-w-0">
            <h3 class="text-xl font-bold text-on-surface mb-2 leading-tight">{{ title }}</h3>
            <p class="text-base text-on-surface-variant leading-relaxed break-words" v-html="message"></p>
          </div>
        </div>
        
        <div class="flex flex-col-reverse sm:flex-row justify-end gap-3 mt-2">
          <button
            class="h-11 px-6 rounded-xl border border-outline-variant text-on-surface-variant font-semibold hover:bg-surface-container transition-all"
            @click="emit('cancel')"
          >
            Cancelar
          </button>
          <button
            class="h-11 px-6 rounded-xl font-semibold hover:shadow-lg active:scale-[0.98] transition-all flex items-center justify-center gap-2 disabled:opacity-50"
            :class="variant === 'danger' ? 'bg-error text-on-error' : 'bg-primary text-on-primary'"
            :disabled="loading"
            @click="emit('confirm')"
          >
            <span v-if="loading" class="animate-spin material-symbols-outlined text-[18px]">sync</span>
            {{ confirmLabel ?? "Confirmar" }}
          </button>
        </div>

      </div>
    </div>
  </Teleport>
</template>