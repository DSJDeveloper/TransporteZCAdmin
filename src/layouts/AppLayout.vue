<script setup lang="ts">
import { ref, computed, watch, watchEffect } from "vue"
import { useRouter, useRoute } from "vue-router"
import { useAuthStore } from "../stores/authStore"

const authStore = useAuthStore()
const router = useRouter()
const route = useRoute()

const sidebarOpen = ref(false)

const today = computed(() => {
  const d = new Date()
  return d.toLocaleDateString("es-ES", { day: "numeric", month: "long", year: "numeric" })
})

async function handleLogout() {
  await authStore.logout()
  router.push({ name: "login" })
}

const userName = computed(() => authStore.user?.name ?? "Usuario")
const userEmail = computed(() => authStore.user?.email ?? "")

watch(route, () => {
  sidebarOpen.value = false
})

function navClass(path: string) {
  const active = route.path.startsWith(path)
    ? "text-primary bg-primary-container/10 border-r-4 border-primary"
    : "text-on-surface-variant hover:bg-surface-container-high border-r-4 border-transparent"
  return `flex items-center gap-md px-md py-sm rounded-lg font-bold transition-all ${active}`
}

const configOpen = ref(false)

watchEffect(() => {
  if (route.path.startsWith("/configuracion")) {
    configOpen.value = true
  }
})

function toggleConfig() {
  configOpen.value = !configOpen.value
}
</script>

<template>
  <div class="min-h-screen bg-background">
    <!-- Backdrop (mobile only) -->
    <Transition name="fade">
      <div
        v-if="sidebarOpen"
        class="fixed inset-0 z-30 bg-black/30 lg:hidden"
        @click="sidebarOpen = false"
      ></div>
    </Transition>

    <!-- Sidebar (single element, responsive) -->
    <aside
      class="fixed left-0 top-0 z-40 h-screen w-64 bg-surface-container-lowest border-r border-outline-variant shadow-sm flex flex-col py-lg transition-transform duration-250 ease-in-out"
      :class="sidebarOpen ? 'translate-x-0' : '-translate-x-full lg:translate-x-0'"
    >
      <div class="px-lg mb-xl">
        <div class="flex items-center justify-between gap-sm">
          <img alt="Transporte Zambrano Castillo" class="h-10 w-auto" src="/logo.png" />
          <button class="lg:hidden text-outline hover:text-on-surface transition-colors" @click="sidebarOpen = false">
            <span class="material-symbols-outlined">close</span>
          </button>
        </div>
      </div>

      <nav class="flex-1 px-md space-y-base overflow-y-auto custom-scrollbar">
        <router-link to="/" :class="navClass('/')">
          <span class="material-symbols-outlined">dashboard</span>
          <span>Panel</span>
        </router-link>
        <router-link to="/clientes" :class="navClass('/clientes')">
          <span class="material-symbols-outlined">group</span>
          <span>Clientes</span>
        </router-link>
        <router-link to="/unidades" :class="navClass('/unidades')">
          <span class="material-symbols-outlined">local_shipping</span>
          <span>Unidades</span>
        </router-link>
        <router-link to="/recargas" :class="navClass('/recargas')">
          <span class="material-symbols-outlined">account_balance_wallet</span>
          <span>Recargas</span>
        </router-link>
        <router-link to="/movimientos" :class="navClass('/movimientos')">
          <span class="material-symbols-outlined">swap_horiz</span>
          <span>Movimientos</span>
        </router-link>
        <router-link to="/configuracion/horarios" :class="navClass('/configuracion/horarios')">
          <span class="material-symbols-outlined">schedule</span>
          <span>Horarios</span>
        </router-link>
        <router-link to="/configuracion/rutas" :class="navClass('/configuracion/rutas')">
          <span class="material-symbols-outlined">alt_route</span>
          <span>Rutas</span>
        </router-link>
        <div v-if="!authStore.isSupervisor">
          <button
            :class="navClass('/configuracion') + ' w-full'"
            @click="toggleConfig"
          >
            <span class="material-symbols-outlined">settings</span>
            <span class="flex-1 text-left">Configuración</span>
            <span
              class="material-symbols-outlined text-[18px] transition-transform duration-200"
              :class="configOpen ? 'rotate-90' : ''"
            >chevron_right</span>
          </button>
          <Transition name="submenu">
            <div v-if="configOpen" class="ml-lg mt-xs space-y-xs border-l-2 border-outline-variant/40 pl-sm">
              <router-link
                to="/configuracion"
                class="flex items-center gap-md px-md py-sm rounded-lg font-bold transition-all text-on-surface-variant hover:bg-surface-container-high border-l-2 border-transparent"
                :class="route.path === '/configuracion' ? 'text-primary border-primary bg-primary-container/10' : ''"
              >
                <span class="material-symbols-outlined text-[18px]">tune</span>
                <span>Parámetros</span>
              </router-link>
              <router-link
                to="/configuracion/info-bancaria"
                class="flex items-center gap-md px-md py-sm rounded-lg font-bold transition-all text-on-surface-variant hover:bg-surface-container-high border-l-2 border-transparent"
                :class="route.path === '/configuracion/info-bancaria' ? 'text-primary border-primary bg-primary-container/10' : ''"
              >
                <span class="material-symbols-outlined text-[18px]">account_balance</span>
                <span>Info. Bancaria</span>
              </router-link>
              <router-link
                to="/configuracion/usuarios"
                class="flex items-center gap-md px-md py-sm rounded-lg font-bold transition-all text-on-surface-variant hover:bg-surface-container-high border-l-2 border-transparent"
                :class="route.path === '/configuracion/usuarios' ? 'text-primary border-primary bg-primary-container/10' : ''"
              >
                <span class="material-symbols-outlined text-[18px]">group</span>
                <span>Usuarios</span>
              </router-link>
            </div>
          </Transition>
        </div>
      </nav>

      <div class="px-lg mt-auto">
        <div class="p-md bg-surface-container rounded-xl flex items-center gap-md">
          <div
            class="w-10 h-10 rounded-full border-2 border-primary-container bg-primary flex items-center justify-center text-white font-bold text-sm shrink-0"
          >
            {{ userName.charAt(0).toUpperCase() }}
          </div>
          <div class="overflow-hidden min-w-0 flex-1">
            <p class="font-bold text-on-surface truncate">{{ userName }}</p>
            <p class="text-[10px] text-on-surface-variant truncate">{{ userEmail }}</p>
            <div
              v-if="authStore.isSupervisor"
              class="mt-xs inline-flex items-center gap-xs px-sm py-0.5 bg-warning/20 text-warning rounded-full text-[10px] font-bold"
            >
              <span>Supervisor</span>
            </div>
          </div>
          <button
            class="ml-auto shrink-0 text-outline hover:text-error transition-colors"
            title="Cerrar sesión"
            @click="handleLogout"
          >
            <span class="material-symbols-outlined">logout</span>
          </button>
        </div>
      </div>
    </aside>

    <!-- Top bar -->
    <header
      class="fixed top-0 right-0 left-0 lg:left-64 h-16 z-20 bg-surface-bright/90 border-b border-outline-variant backdrop-blur-md shadow-sm flex justify-between items-center px-lg"
    >
      <div class="flex items-center gap-md flex-1 min-w-0">
        <button class="lg:hidden text-on-surface-variant hover:text-primary transition-colors shrink-0" @click="sidebarOpen = true">
          <span class="material-symbols-outlined">menu</span>
        </button>
        <div class="relative w-full max-w-md focus-within:ring-2 focus-within:ring-primary/20 transition-all rounded-lg">
          <span class="material-symbols-outlined absolute left-3 top-1/2 -translate-y-1/2 text-outline">search</span>
          <input
            class="w-full pl-10 pr-4 py-2 bg-surface-container-low border-none rounded-lg text-body-md focus:ring-0"
            placeholder="Buscar centros logísticos, envíos, clientes..."
            type="text"
          />
        </div>
      </div>
      <div class="flex items-center gap-lg shrink-0">
        <div class="flex items-center gap-md border-r border-outline-variant pr-lg">
          <button class="relative hover:text-primary transition-colors">
            <span class="material-symbols-outlined">notifications</span>
            <span class="absolute top-0 right-0 w-2 h-2 bg-error rounded-full border-2 border-surface-bright"></span>
          </button>
          <button class="hover:text-primary transition-colors">
            <span class="material-symbols-outlined">help_outline</span>
          </button>
        </div>
        <div class="hidden sm:flex items-center gap-sm">
          <span class="text-body-md font-semibold text-on-surface">{{ today }}</span>
          <span class="material-symbols-outlined text-outline">calendar_today</span>
        </div>
      </div>
    </header>

    <!-- Main content -->
    <main class="ml-0 lg:ml-64 pt-16 min-h-screen">
      <router-view />
    </main>
  </div>
</template>

<style scoped>
.fade-enter-active,
.fade-leave-active {
  transition: opacity 0.2s ease;
}
.fade-enter-from,
.fade-leave-to {
  opacity: 0;
}

.submenu-enter-active,
.submenu-leave-active {
  transition: all 0.2s ease;
}
.submenu-enter-from,
.submenu-leave-to {
  opacity: 0;
  transform: translateY(-4px);
}

.custom-scrollbar::-webkit-scrollbar {
  width: 4px;
}
.custom-scrollbar::-webkit-scrollbar-track {
  background: transparent;
}
.custom-scrollbar::-webkit-scrollbar-thumb {
  background: #cbd5e1;
  border-radius: 10px;
}
</style>
