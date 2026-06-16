<script setup lang="ts">
import { useAuthStore } from "../stores/authStore"

const auth = useAuthStore()

defineProps<{
  detailed?: boolean
}>()
</script>

<template>
  <div v-if="auth.isSupervisor">
    <!-- Detailed variant (HistorialMovimientos style) -->
    <div
      v-if="detailed"
      class="flex items-start gap-md px-lg py-sm bg-warning/10 border border-warning/30 rounded-xl text-warning-dark text-body-sm"
    >
      <span class="material-symbols-outlined text-[18px] shrink-0 mt-[2px]">visibility</span>
      <div class="flex flex-col gap-xs">
        <p class="font-bold text-warning-darker">
          Modo supervisor: Viendo
          <strong class="font-bold">{{ auth.assignedRouteCount }} {{ auth.assignedRouteCount === 1 ? 'ruta' : 'rutas' }}</strong>
        </p>
        <p v-if="auth.assignedRouteNames.length" class="text-neutral-600 dark:text-neutral-300">
          <span class="font-medium text-warning-dark">{{ auth.assignedRouteNames.join(', ') }}</span>
        </p>
      </div>
    </div>

    <!-- Simple variant (Clientes/Unidades/HistorialRecargas style) -->
    <div
      v-else
      class="flex items-center gap-md px-lg py-sm bg-warning/10 border border-warning/30 rounded-xl text-warning text-body-sm font-bold"
    >
      <span class="material-symbols-outlined text-[18px]">visibility</span>
      <span>Visibilidad limitada a {{ auth.assignedRouteCount }} {{ auth.assignedRouteCount === 1 ? 'ruta' : 'rutas' }} asignada(s)</span>
    </div>
  </div>
</template>
