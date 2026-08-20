<script setup lang="ts">
import { ref } from "vue"
import { useRouter } from "vue-router"
import { useAuthStore } from "../stores/authStore"

const authStore = useAuthStore()
const router = useRouter()

const username = ref("")
const password = ref("")
const passwordVisible = ref(false)

async function handleSubmit() {
  await authStore.login(username.value, password.value)
  if (authStore.user) {
    router.push({ name: "home" })
  }
}
</script>

<template>
  <div class="flex w-full min-h-screen bg-background overflow-hidden">
    <!-- Left: Branding (Desktop) -->
    <div class="hidden md:flex relative flex-1 items-center justify-center split-image-container">
      <img
        alt="Logística de Transporte"
        class="absolute inset-0 h-full w-full object-cover"
        src="https://lh3.googleusercontent.com/aida-public/AB6AXuBweublNoOBeeQ5-F9wFM43UnJNyVgIeag0zfdRt3InxY4A3KfJCFX-IBvRxxevpSyopxSb8YtuZ0Dmz0T2YdtlUqIuAM2JpBry9o6MTna0bsjev2PVeDyDiq44gWnvqQhQvXpGB2G-xtWOgnl16Q0aU6LlzkEUFPt5cObzUfR8vx44Mv_4BrYIYAbEZeUQwLuQqZ1ji_zppE538va3qhonrGDlC1Xy6XpUWn_7eJApvJwAaqQAnBGDA-5g7jix7BIWGDIRtH-GupA"
      />
      <div class="relative z-10 p-margin-desktop text-white max-w-lg">
        <h1 class="font-headline-lg text-headline-lg mb-md leading-tight text-white drop-shadow-lg">
          Impulsando la Logística con Precisión
        </h1>
        <p class="font-body-lg text-body-lg text-white/90 drop-shadow">
          LogiTrack gestiona cada kilómetro de su flota con tecnología de vanguardia y confiabilidad operativa.
        </p>
      </div>
    </div>
    <!-- Right: Form -->
    <div class="flex-1 flex flex-col items-center justify-center px-margin-mobile md:px-xl py-xl bg-surface relative">
      <div class="w-full max-w-[400px] mb-xl flex flex-col items-center md:items-start">
        <div class="logo-wrapper">
          <img alt="Transporte Zambrano Castillo" src="/logo.png" />
        </div>
        <h2 class="font-headline-md text-headline-md text-on-surface mb-xs">Iniciar Sesión</h2>
        <p class="font-body-md text-body-md text-on-surface-variant">Ingrese sus credenciales.</p>
      </div>
      <div class="w-full max-w-[400px]">
        <form class="space-y-lg" @submit.prevent="handleSubmit">
          <div class="space-y-base">
            <label
              class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider ml-1"
              for="username"
            >Usuario</label>
            <div class="relative group">
              <span
                class="material-symbols-outlined absolute left-md top-1/2 -translate-y-1/2 text-outline-variant group-focus-within:text-primary transition-colors"
              >person</span>
              <input
                id="username"
                v-model="username"
                class="w-full h-12 pl-11 pr-md bg-surface-container-lowest border border-outline-variant rounded-xl focus:ring-2 focus:ring-primary focus:border-primary transition-all font-body-md text-body-md text-on-surface placeholder:text-outline/50"
                placeholder="usuario"
                type="text"
                autocomplete="username"
              />
            </div>
          </div>
          <div class="space-y-base">
            <div class="flex justify-between items-center">
              <label
                class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider ml-1"
                for="password"
              >Contraseña</label>
              <a class="font-label-md text-label-md text-primary hover:underline transition-all" href="#">¿Olvidó su clave?</a>
            </div>
            <div class="relative group">
              <span
                class="material-symbols-outlined absolute left-md top-1/2 -translate-y-1/2 text-outline-variant group-focus-within:text-primary transition-colors"
              >lock</span>
              <input
                id="password"
                v-model="password"
                class="w-full h-12 pl-11 pr-11 bg-surface-container-lowest border border-outline-variant rounded-xl focus:ring-2 focus:ring-primary focus:border-primary transition-all font-body-md text-body-md text-on-surface placeholder:text-outline/50"
                :type="passwordVisible ? 'text' : 'password'"
                placeholder="••••••••••••"
                autocomplete="current-password"
              />
              <button
                type="button"
                class="absolute right-md top-1/2 -translate-y-1/2 text-outline-variant hover:text-on-surface-variant transition-colors"
                @click="passwordVisible = !passwordVisible"
              >
                <span class="material-symbols-outlined">{{ passwordVisible ? 'visibility_off' : 'visibility' }}</span>
              </button>
            </div>
          </div>
          <button
            type="submit"
            :disabled="authStore.loading"
            class="w-full h-12 bg-primary-container text-on-primary-container font-headline-sm text-headline-sm rounded-xl hover:shadow-lg active:scale-[0.98] transition-all flex items-center justify-center gap-xs disabled:opacity-70 disabled:cursor-not-allowed"
          >
            <template v-if="authStore.loading">
              <span class="animate-spin material-symbols-outlined">sync</span>
              Procesando...
            </template>
            <template v-else>
              Entrar
              <span class="material-symbols-outlined">arrow_forward</span>
            </template>
          </button>
          <p v-if="authStore.error" class="text-error text-body-md text-center">{{ authStore.error }}</p>
        </form>
        <div class="mt-xl pt-lg border-t border-outline-variant text-center">
          <!-- <p class="font-label-md text-label-md text-on-surface-variant">
            ¿Necesita ayuda?
            <a class="text-primary hover:underline font-bold" href="#">Contactar Soporte IT</a>
          </p> -->
          <div class="mt-md flex justify-center gap-md">
            <span class="font-label-md text-label-md text-outline">v1.0.0</span>
            <!-- <span class="font-label-md text-label-md text-outline">•</span> -->
            <!-- <span class="font-label-md text-label-md text-outline">LogiTrack Enterprise</span> -->
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.split-image-container::after {
  content: "";
  position: absolute;
  inset: 0;
  background: linear-gradient(to right, rgba(11, 28, 48, 0.4), transparent);
}
.logo-wrapper {
  width: 208px;
  height: 112px;
  overflow: hidden;
  display: flex;
  align-items: center;
  justify-content: center;
  border-radius: 12px;
}
.logo-wrapper img {
  width: auto;
  height: 100%;
  transform: scale(1.6);
  object-fit: cover;
}
</style>
