<template>
  <router-view />
  <Teleport to="body">
    <div
      v-if="showUpdateBanner"
      class="fixed bottom-0 left-0 right-0 z-[9999] bg-primary text-on-primary px-lg py-md shadow-2xl flex items-center justify-between gap-md animate-slide-up"
    >
      <div class="flex items-center gap-md">
        <span class="material-symbols-outlined">system_update</span>
        <span class="font-bold">Nueva versión disponible</span>
        <span class="text-on-primary/80 text-body-md hidden sm:inline">Actualiza para ver los últimos cambios</span>
      </div>
      <div class="flex items-center gap-sm">
        <button
          class="px-md py-sm rounded-lg bg-on-primary/20 hover:bg-on-primary/30 font-bold transition-all text-sm whitespace-nowrap"
          @click="dismissVersion"
        >Ignorar</button>
        <button
          class="px-md py-sm rounded-lg bg-on-primary text-primary font-bold hover:shadow-lg transition-all text-sm whitespace-nowrap"
          @click="refreshApp"
        >Actualizar ahora</button>
      </div>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { useTabTracker } from './composables/useTabTracker'

useTabTracker()

const BUILD_HASH = typeof __APP_BUILD_HASH__ !== 'undefined' ? __APP_BUILD_HASH__ : 'dev'
const POLL_INTERVAL = 5 * 60 * 1000

const showUpdateBanner = ref(false)
let pollTimer: ReturnType<typeof setInterval> | null = null

async function checkVersion() {
  try {
    const res = await fetch(`/version.json?t=${Date.now()}`, { cache: 'no-store' })
    if (!res.ok) return
    const data = await res.json() as { version: string }
    if (data.version && data.version !== BUILD_HASH && BUILD_HASH !== 'dev') {
      showUpdateBanner.value = true
    }
  } catch {
    // Silently fail — no version.json means no build hash tracking
  }
}

function refreshApp() {
  localStorage.setItem('_dismissed_version', BUILD_HASH)
  window.location.reload()
}

function dismissVersion() {
  showUpdateBanner.value = false
}

onMounted(() => {
  if (BUILD_HASH === 'dev') return
  const dismissed = localStorage.getItem('_dismissed_version')
  if (dismissed === BUILD_HASH) return
  checkVersion()
  pollTimer = setInterval(checkVersion, POLL_INTERVAL)
})

onUnmounted(() => {
  if (pollTimer) clearInterval(pollTimer)
})
</script>

<style>
@keyframes slide-up {
  from { transform: translateY(100%); }
  to { transform: translateY(0); }
}
.animate-slide-up {
  animation: slide-up 0.3s ease-out;
}
</style>
