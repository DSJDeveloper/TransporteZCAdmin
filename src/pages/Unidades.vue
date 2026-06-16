<script setup lang="ts">
import { ref, computed, reactive, watch, onMounted } from "vue"
import { useUnitStore } from "../stores/unitStore"
import { useRouteStore } from "../stores/routeStore"
import SupervisorBanner from "../components/SupervisorBanner.vue"
import { useAuthStore } from "../stores/authStore"
import { uploadUnitPhoto } from "../services/unitService"
import type { Unit, UnitForm } from "../services/unitService"

const store = useUnitStore()
const routeStore = useRouteStore()
const auth = useAuthStore()

const search = ref("")
const page = ref(1)
const perPage = ref(10)
const sortField = ref("id")
const sortAsc = ref(true)

const dialogOpen = ref(false)
const editing = ref<Unit | null>(null)
const saving = ref(false)
const uploadingPhoto = ref(false)
const showPassword = ref(false)
const photoPreview = ref<string | null>(null)
const form = ref<UnitForm>({ name: "", number: "", plate: "", status: 0, driver: "", idroute: null, email: "", password: "", photo_url: null })
const errors = reactive<Record<string, string>>({})

const refreshing = ref(false)
async function refreshData() {
  refreshing.value = true
  await store.fetchAll()
  refreshing.value = false
}

const deleting = ref<Unit | null>(null)
const deletingConfirm = ref(false)

const filtered = computed(() => {
  const q = search.value.toLowerCase().trim()
  if (!q) return store.list
  return store.list.filter(
    (u) =>
      u.name.toLowerCase().includes(q) ||
      u.driver.toLowerCase().includes(q) ||
      u.plate.toLowerCase().includes(q) ||
      u.number.toLowerCase().includes(q) ||
      u.email.toLowerCase().includes(q) ||
      (u.route_name ?? "").toLowerCase().includes(q),
  )
})

const totalPages = computed(() => Math.max(1, Math.ceil(filtered.value.length / perPage.value)))

function compare(a: Unit, b: Unit, field: string): number {
  const va = (a as any)[field]
  const vb = (b as any)[field]
  if (typeof va === "number" && typeof vb === "number") return va - vb
  return String(va ?? "").localeCompare(String(vb ?? ""), "es")
}

const sorted = computed(() => {
  const list = filtered.value
  if (!sortField.value) return list
  return [...list].sort((a, b) => {
    const cmp = compare(a, b, sortField.value)
    return sortAsc.value ? cmp : -cmp
  })
})

const paginated = computed(() => {
  const start = (page.value - 1) * perPage.value
  return sorted.value.slice(start, start + perPage.value)
})

const pageRange = computed(() => {
  const total = totalPages.value
  const current = page.value
  const pages: (number | string)[] = []
  if (total <= 7) {
    for (let i = 1; i <= total; i++) pages.push(i)
  } else {
    pages.push(1)
    if (current > 3) pages.push("...")
    const start = Math.max(2, current - 1)
    const end = Math.min(total - 1, current + 1)
    for (let i = start; i <= end; i++) pages.push(i)
    if (current < total - 2) pages.push("...")
    pages.push(total)
  }
  return pages
})

const fromRecord = computed(() => (page.value - 1) * perPage.value + 1)
const toRecord = computed(() => Math.min(page.value * perPage.value, filtered.value.length))

function goToPage(p: number | string) {
  if (typeof p !== "number") return
  if (p < 1 || p > totalPages.value) return
  page.value = p
}

watch(search, () => { page.value = 1 })
watch(perPage, () => { page.value = 1 })
watch([sortField, sortAsc], () => { page.value = 1 })

const columns = [
  { key: "id", label: "ID" },
  { key: "photo_url", label: "FOTO" },
  { key: "name", label: "UNIDAD" },
  { key: "driver", label: "CONDUCTOR" },
  { key: "number", label: "NÚMERO" },
  { key: "plate", label: "PLACA" },
  { key: "route_name", label: "RUTA" },
  { key: "status", label: "ESTADO" },
]

function sortIcon(key: string): string {
  if (sortField.value !== key) return "unfold_more"
  return sortAsc.value ? "arrow_upward" : "arrow_downward"
}

function toggleSort(key: string) {
  if (sortField.value === key) {
    sortAsc.value = !sortAsc.value
  } else {
    sortField.value = key
    sortAsc.value = true
  }
}

function validate(): boolean {
  const e: Record<string, string> = {}
  if (!form.value.name.trim()) e.name = "El nombre de la unidad es obligatorio"
  if (!form.value.number.trim()) e.number = "El número es obligatorio"
  if (!form.value.plate.trim()) e.plate = "La placa es obligatoria"
  if (!form.value.driver.trim()) e.driver = "El nombre del conductor es obligatorio"
  if (form.value.email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(form.value.email)) {
    e.email = "El formato del correo no es válido"
  }
  if (form.value.email && !editing.value && form.value.password.length < 4) {
    e.password = "La contraseña debe tener al menos 4 caracteres"
  }
  if (editing.value && form.value.password && form.value.password.length < 4) {
    e.password = "La contraseña debe tener al menos 4 caracteres"
  }
  Object.assign(errors, e)
  return Object.keys(errors).length === 0
}

function clearErrors() {
  for (const key of Object.keys(errors)) {
    delete errors[key]
  }
}

function openCreate() {
  editing.value = null
  form.value = { name: "", number: "", plate: "", status: 0, driver: "", idroute: null, email: "", password: "", photo_url: null }
  photoPreview.value = null
  clearErrors()
  dialogOpen.value = true
}

function openEdit(u: Unit) {
  editing.value = u
  form.value = { name: u.name, number: u.number, plate: u.plate, status: u.status, driver: u.driver, idroute: u.idroute, email: u.email, password: "", photo_url: u.photo_url }
  photoPreview.value = u.photo_url
  showPassword.value = false
  clearErrors()
  dialogOpen.value = true
}

async function save() {
  clearErrors()
  if (!validate()) return
  saving.value = true
  try {
    if (photoFile.value) {
      const tempId = editing.value?.id ?? -Date.now()
      form.value.photo_url = await uploadUnitPhoto(photoFile.value, tempId)
    }
    const ok = editing.value
      ? await store.update(editing.value.id, form.value)
      : await store.create(form.value)
    if (ok) {
      dialogOpen.value = false
    }
  } finally {
    saving.value = false
  }
}

const photoFile = ref<File | null>(null)

function onPhotoSelected(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return
  photoFile.value = file
  const reader = new FileReader()
  reader.onload = (e) => {
    photoPreview.value = e.target?.result as string
  }
  reader.readAsDataURL(file)
}

function removePhoto() {
  photoFile.value = null
  photoPreview.value = null
  form.value.photo_url = null
}

function confirmDelete(u: Unit) {
  deleting.value = u
  deletingConfirm.value = true
}

async function doDelete() {
  if (!deleting.value) return
  const ok = await store.remove(deleting.value.id)
  if (ok) {
    deletingConfirm.value = false
    deleting.value = null
  }
}

onMounted(() => {
  store.fetchAll()
  routeStore.fetchAll()
})
</script>

<template>
  <div class="p-margin-mobile md:p-margin-desktop min-h-screen">
    <!-- Header -->
    <div class="flex flex-col sm:flex-row sm:justify-between sm:items-end gap-md mb-lg">
      <div>
        <h2 class="font-headline-lg text-headline-lg text-on-surface">Gestión de Unidades</h2>
        <p class="font-body-lg text-body-lg text-on-surface-variant hidden sm:block">Control centralizado de flota y conductores</p>
      </div>
      <button
        class="bg-primary hover:bg-surface-tint text-on-primary px-lg py-sm rounded-xl font-headline-sm text-headline-sm flex items-center justify-center gap-sm transition-all shadow-md active:scale-95 w-full sm:w-auto"
        @click="openCreate"
      >
        <span class="material-symbols-outlined">add_circle</span>
        <span>Nueva Unidad</span>
      </button>
    </div>

    <SupervisorBanner detailed class="mb-lg" />

    <!-- Toolbar -->
    <section class="bg-surface-container-lowest rounded-xl border border-outline-variant shadow-sm overflow-hidden">
      <div class="p-md md:p-lg border-b border-outline-variant flex flex-col md:flex-row md:items-center md:justify-between gap-md bg-surface-container-low/30">
        <h4 class="font-headline-sm text-headline-sm text-on-surface">Lista de Unidades</h4>
        <div class="flex items-center gap-md w-full md:w-auto">
          <div class="flex items-center gap-xs text-body-md text-on-surface-variant whitespace-nowrap">
            <span class="hidden md:inline">Mostrar</span>
            <select
              v-model.number="perPage"
              class="bg-surface-container-lowest border border-outline-variant rounded-lg text-body-md py-1 pl-2 pr-1 focus:ring-primary focus:border-primary outline-none"
            >
              <option :value="10">10</option>
            <option :value="25">25</option>
            <option :value="50">50</option>
            <option :value="100">100</option>
            <option :value="150">150</option>
            <option :value="500">500</option>
            </select>
            <span class="hidden md:inline">registros</span>
          </div>
          <button
            class="h-7 w-7 flex items-center justify-center rounded-lg border border-outline-variant text-on-surface-variant hover:bg-surface-container transition-all shrink-0 disabled:opacity-40"
            :disabled="refreshing"
            @click="refreshData"
            title="Refrescar datos"
          >
            <span class="material-symbols-outlined text-[18px]" :class="{ 'animate-spin': refreshing }">sync</span>
          </button>
          <div class="relative flex-1 md:flex-none">
            <span class="material-symbols-outlined absolute left-3 top-1/2 -translate-y-1/2 text-outline text-[18px]">search</span>
            <input
              v-model="search"
              class="w-full md:w-56 pl-9 pr-3 py-1.5 bg-surface-container-low border border-outline-variant rounded-lg text-body-md focus:border-primary outline-none transition-all"
              placeholder="Buscar unidades..."
              type="text"
            />
          </div>
        </div>
      </div>

      <!-- Loading state -->
      <div v-if="store.loading" class="p-xl text-center text-on-surface-variant">
        <span class="animate-spin material-symbols-outlined inline-block">sync</span>
        <p class="mt-2">Cargando unidades...</p>
      </div>

      <!-- Empty state -->
      <div v-else-if="!filtered.length" class="p-xl text-center text-on-surface-variant">
        <span class="material-symbols-outlined text-[48px] text-outline">local_shipping</span>
        <p class="mt-2">No se encontraron unidades</p>
      </div>

      <!-- Data: table (md+) or cards (mobile) -->
      <template v-else>
        <!-- Desktop table -->
        <div class="hidden md:block overflow-x-auto">
          <table class="w-full text-left font-body-md text-body-md border-collapse">
            <thead class="bg-surface-container-high/20 border-b border-outline-variant">
              <tr>
                <th v-for="col in columns" :key="col.key"
                  class="px-lg py-md font-bold text-on-surface-variant uppercase text-[11px] tracking-widest cursor-pointer select-none hover:text-on-surface transition-colors"
                  :class="col.key === 'status' ? 'text-center' : ''"
                  @click="toggleSort(col.key)"
                >
                  <span class="inline-flex items-center gap-1">
                    {{ col.label }}
                    <span class="material-symbols-outlined text-[14px] leading-none"
                      :class="sortField === col.key ? 'text-primary' : 'text-outline/40'">{{ sortIcon(col.key) }}</span>
                  </span>
                </th>
                <th class="px-lg py-md font-bold text-on-surface-variant uppercase text-[11px] tracking-widest text-right">ACCIONES</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-outline-variant">
              <tr v-for="u in paginated" :key="u.id" class="hover:bg-primary-container/5 transition-colors group">
                <td class="px-lg py-md text-outline font-bold">{{ String(u.id).padStart(2, "0") }}</td>
                <td class="px-lg py-md">
                  <div class="w-8 h-8 rounded-full overflow-hidden bg-surface-container-high flex items-center justify-center">
                    <img v-if="u.photo_url" :src="u.photo_url" alt="" class="w-full h-full object-cover" />
                    <span v-else class="material-symbols-outlined text-[18px] text-outline">person</span>
                  </div>
                </td>
                <td class="px-lg py-md">
                  <div class="flex items-center gap-sm">
                    <div class="w-8 h-8 rounded bg-primary/10 flex items-center justify-center text-primary">
                      <span class="material-symbols-outlined text-[18px]">local_shipping</span>
                    </div>
                    <span class="font-bold text-on-surface">{{ u.name }}</span>
                  </div>
                </td>
                <td class="px-lg py-md text-on-surface-variant">{{ u.driver }}</td>
                <td class="px-lg py-md">
                  <code class="bg-surface-container-high px-xs rounded text-primary font-bold">{{ u.number }}</code>
                </td>
                <td class="px-lg py-md font-mono text-on-surface">{{ u.plate }}</td>
                <td class="px-lg py-md text-on-surface-variant">
                  <span v-if="u.route_name && u.route_name !== 'Sin ruta'" class="inline-flex items-center gap-1">
                    <span class="material-symbols-outlined text-[16px] text-outline">alt_route</span>
                    {{ u.route_name }}
                  </span>
                  <span v-else class="text-outline italic">Sin ruta</span>
                </td>
                <td class="px-lg py-md text-center">
                  <span
                    v-if="u.status === 0"
                    class="bg-tertiary-fixed text-on-tertiary-fixed px-sm py-1 rounded-full text-[12px] font-bold"
                  >Activo</span>
                  <span
                    v-else
                    class="bg-error-container text-on-error-container px-sm py-1 rounded-full text-[12px] font-bold"
                  >Inactivo</span>
                </td>
                <td class="px-lg py-md text-right">
                  <div class="flex justify-end gap-xs opacity-40 group-hover:opacity-100 transition-all duration-200">
                    <button class="p-xs hover:bg-primary/10 rounded-lg text-primary transition-colors" title="Editar" @click="openEdit(u)">
                      <span class="material-symbols-outlined">edit</span>
                    </button>
                    <button class="p-xs hover:bg-error/10 rounded-lg text-error transition-colors" title="Eliminar" @click="confirmDelete(u)">
                      <span class="material-symbols-outlined">delete</span>
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <!-- Mobile cards -->
        <div class="md:hidden divide-y divide-outline-variant">
          <div v-for="u in paginated" :key="u.id" class="p-md space-y-sm">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-sm">
                <div class="w-8 h-8 rounded-full overflow-hidden bg-surface-container-high flex items-center justify-center shrink-0">
                  <img v-if="u.photo_url" :src="u.photo_url" alt="" class="w-full h-full object-cover" />
                  <span v-else class="material-symbols-outlined text-[18px] text-outline">person</span>
                </div>
                <div class="w-8 h-8 rounded bg-primary/10 flex items-center justify-center text-primary shrink-0">
                  <span class="material-symbols-outlined text-[18px]">local_shipping</span>
                </div>
                <div>
                  <span class="font-bold text-on-surface">{{ u.name }}</span>
                  <code class="ml-2 bg-surface-container-high px-1.5 rounded text-primary font-bold text-[12px]">{{ u.number }}</code>
                </div>
              </div>
              <span
                v-if="u.status === 1"
                class="bg-tertiary-fixed text-on-tertiary-fixed px-2 py-0.5 rounded-full text-[11px] font-bold"
              >Activo</span>
              <span
                v-else
                class="bg-error-container text-on-error-container px-2 py-0.5 rounded-full text-[11px] font-bold"
              >Inactivo</span>
            </div>
            <div class="flex items-center justify-between text-body-md text-on-surface-variant">
              <div class="flex items-center gap-2">
                <span class="material-symbols-outlined text-[16px] text-outline">person</span>
                <span>{{ u.driver }}</span>
              </div>
              <span class="font-mono text-on-surface text-[13px]">{{ u.plate }}</span>
            </div>
            <div class="text-body-md text-on-surface-variant flex items-center gap-1">
              <span class="material-symbols-outlined text-[16px] text-outline">alt_route</span>
              <span v-if="u.route_name && u.route_name !== 'Sin ruta'">{{ u.route_name }}</span>
              <span v-else class="text-outline italic">Sin ruta</span>
            </div>
            <div class="flex justify-end gap-xs pt-xs">
              <button
                class="flex-1 flex items-center justify-center gap-1 py-2 rounded-lg border border-outline-variant text-primary font-bold text-[13px] hover:bg-primary-container/10 transition-colors"
                @click="openEdit(u)"
              >
                <span class="material-symbols-outlined text-[18px]">edit</span>
                Editar
              </button>
              <button
                class="flex-1 flex items-center justify-center gap-1 py-2 rounded-lg border border-outline-variant text-error font-bold text-[13px] hover:bg-error-container/10 transition-colors"
                @click="confirmDelete(u)"
              >
                <span class="material-symbols-outlined text-[18px]">delete</span>
                Eliminar
              </button>
            </div>
          </div>
        </div>
      </template>

      <!-- Pagination -->
      <div class="p-md md:p-lg border-t border-outline-variant flex flex-col md:flex-row items-center justify-between gap-md bg-surface-container-low/20">
        <p class="font-body-md text-body-md text-on-surface-variant text-center md:text-left">
          Mostrando <span class="font-bold text-on-surface">{{ fromRecord }}-{{ toRecord }}</span> de <span class="font-bold text-on-surface">{{ filtered.length }}</span> registros
        </p>
        <div class="flex items-center gap-xs">
          <button
            class="p-xs rounded-lg hover:bg-surface-container-high text-secondary disabled:opacity-30 transition-colors"
            :disabled="page <= 1"
            @click="goToPage(page - 1)"
          >
            <span class="material-symbols-outlined">chevron_left</span>
          </button>
          <div class="flex gap-xs">
            <template v-for="p in pageRange" :key="p">
              <button
                v-if="p === '...'"
                class="px-1 self-center text-outline text-label-md"
                disabled
              >...</button>
              <button
                v-else
                class="w-8 h-8 rounded-lg text-label-md font-bold transition-colors"
                :class="p === page ? 'bg-primary text-on-primary' : 'hover:bg-surface-container-high text-on-surface-variant'"
                @click="goToPage(p)"
              >{{ p }}</button>
            </template>
          </div>
          <button
            class="p-xs rounded-lg hover:bg-surface-container-high text-secondary disabled:opacity-30 transition-colors"
            :disabled="page >= totalPages"
            @click="goToPage(page + 1)"
          >
            <span class="material-symbols-outlined">chevron_right</span>
          </button>
        </div>
      </div>
    </section>

    <!-- Create/Edit Dialog -->
    <Teleport to="body">
      <div v-if="dialogOpen" class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="absolute inset-0 bg-black/30 backdrop-blur-sm" @click="dialogOpen = false"></div>
        <div class="relative bg-surface-container-lowest rounded-xl shadow-2xl border border-outline-variant w-full max-w-lg mx-auto p-md md:p-xl max-h-[90vh] overflow-y-auto">
          <div class="flex items-center justify-between mb-lg">
            <h3 class="font-headline-sm text-headline-sm text-on-surface">
              {{ editing ? "Editar Unidad" : "Nueva Unidad" }}
            </h3>
            <button class="text-outline hover:text-on-surface transition-colors" @click="dialogOpen = false">
              <span class="material-symbols-outlined">close</span>
            </button>
          </div>
          <form @submit.prevent="save" class="space-y-lg">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-lg">
              <div class="space-y-base md:col-span-2">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Nombre de la Unidad</label>
                <input
                  v-model="form.name"
                  :class="[
                    'w-full h-11 px-md bg-surface-container-lowest border rounded-xl transition-all font-body-md text-body-md outline-none',
                    errors.name
                      ? 'border-error focus:ring-2 focus:ring-error focus:border-error'
                      : 'border-outline-variant focus:ring-2 focus:ring-primary focus:border-primary'
                  ]"
                  placeholder="Ej. La Blanca"
                  @input="errors.name && delete errors.name"
                />
                <p v-if="errors.name" class="text-error text-[12px] font-bold">{{ errors.name }}</p>
              </div>
              <div class="space-y-base">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Número</label>
                <input
                  v-model="form.number"
                  :class="[
                    'w-full h-11 px-md bg-surface-container-lowest border rounded-xl transition-all font-body-md text-body-md outline-none',
                    errors.number
                      ? 'border-error focus:ring-2 focus:ring-error focus:border-error'
                      : 'border-outline-variant focus:ring-2 focus:ring-primary focus:border-primary'
                  ]"
                  placeholder="Ej. 01"
                  @input="errors.number && delete errors.number"
                />
                <p v-if="errors.number" class="text-error text-[12px] font-bold">{{ errors.number }}</p>
              </div>
              <div class="space-y-base">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Placa</label>
                <input
                  v-model="form.plate"
                  :class="[
                    'w-full h-11 px-md bg-surface-container-lowest border rounded-xl transition-all font-body-md text-body-md outline-none',
                    errors.plate
                      ? 'border-error focus:ring-2 focus:ring-error focus:border-error'
                      : 'border-outline-variant focus:ring-2 focus:ring-primary focus:border-primary'
                  ]"
                  placeholder="Ej. 516AA6G"
                  @input="errors.plate && delete errors.plate"
                />
                <p v-if="errors.plate" class="text-error text-[12px] font-bold">{{ errors.plate }}</p>
              </div>
              <div class="space-y-base">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Conductor</label>
                <input
                  v-model="form.driver"
                  :class="[
                    'w-full h-11 px-md bg-surface-container-lowest border rounded-xl transition-all font-body-md text-body-md outline-none',
                    errors.driver
                      ? 'border-error focus:ring-2 focus:ring-error focus:border-error'
                      : 'border-outline-variant focus:ring-2 focus:ring-primary focus:border-primary'
                  ]"
                  placeholder="Nombre del conductor"
                  @input="errors.driver && delete errors.driver"
                />
                <p v-if="errors.driver" class="text-error text-[12px] font-bold">{{ errors.driver }}</p>
              </div>
              <div class="space-y-base">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Ruta</label>
                <select
                  v-model.number="form.idroute"
                  class="w-full h-11 px-md bg-surface-container-lowest border border-outline-variant rounded-xl focus:ring-2 focus:ring-primary focus:border-primary transition-all font-body-md text-body-md text-on-surface"
                >
                  <option :value="null">Sin ruta</option>
                  <option
                    v-for="r in routeStore.list"
                    :key="r.id"
                    :value="r.id"
                  >{{ r.code }} - {{ r.description }}</option>
                </select>
              </div>
              <div class="space-y-base md:col-span-2">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Foto de la Unidad</label>
                <div class="flex items-center gap-md">
                  <div class="w-16 h-16 rounded-full overflow-hidden bg-surface-container-high flex items-center justify-center shrink-0 border border-outline-variant">
                    <img v-if="photoPreview" :src="photoPreview" alt="" class="w-full h-full object-cover" />
                    <span v-else class="material-symbols-outlined text-[32px] text-outline">person</span>
                  </div>
                  <div class="flex flex-col gap-xs">
                    <label
                      class="h-9 px-md rounded-lg bg-primary text-on-primary font-bold text-[13px] flex items-center gap-1 cursor-pointer hover:bg-surface-tint transition-all"
                    >
                      <span class="material-symbols-outlined text-[18px]">upload</span>
                      Subir foto
                      <input type="file" accept="image/*" class="hidden" @change="onPhotoSelected" />
                    </label>
                    <button
                      v-if="photoPreview"
                      type="button"
                      class="h-9 px-md rounded-lg border border-outline-variant text-error font-bold text-[13px] flex items-center gap-1 hover:bg-error-container/10 transition-all"
                      @click="removePhoto"
                    >
                      <span class="material-symbols-outlined text-[18px]">delete</span>
                      Eliminar
                    </button>
                  </div>
                </div>
              </div>
              <div class="space-y-base">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">
                  Correo del Conductor
                  <span class="text-outline font-normal normal-case">(para inicio de sesión)</span>
                </label>
                <input
                  v-model="form.email"
                  :class="[
                    'w-full h-11 px-md bg-surface-container-lowest border rounded-xl transition-all font-body-md text-body-md outline-none',
                    errors.email
                      ? 'border-error focus:ring-2 focus:ring-error focus:border-error'
                      : 'border-outline-variant focus:ring-2 focus:ring-primary focus:border-primary'
                  ]"
                  placeholder="conductor@ejemplo.com"
                  type="email"
                  @input="errors.email && delete errors.email"
                />
                <p v-if="errors.email" class="text-error text-[12px] font-bold">{{ errors.email }}</p>
              </div>
              <div class="space-y-base">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">
                  Contraseña
                  <span class="text-outline font-normal normal-case">{{ editing ? '(dejar vacío para mantener)' : '' }}</span>
                </label>
                <div class="relative">
                  <input
                    v-model="form.password"
                    :class="[
                      'w-full h-11 px-md bg-surface-container-lowest border rounded-xl transition-all font-body-md text-body-md outline-none pr-11',
                      errors.password
                        ? 'border-error focus:ring-2 focus:ring-error focus:border-error'
                        : 'border-outline-variant focus:ring-2 focus:ring-primary focus:border-primary'
                    ]"
                    placeholder="Mín. 4 caracteres"
                    :type="showPassword ? 'text' : 'password'"
                    @input="errors.password && delete errors.password"
                  />
                  <button
                    type="button"
                    class="absolute right-3 top-1/2 -translate-y-1/2 text-outline hover:text-on-surface transition-colors"
                    @click="showPassword = !showPassword"
                  >
                    <span class="material-symbols-outlined text-[20px]">{{ showPassword ? 'visibility_off' : 'visibility' }}</span>
                  </button>
                </div>
                <p v-if="errors.password" class="text-error text-[12px] font-bold">{{ errors.password }}</p>
              </div>
              <div class="space-y-base">
                <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Estado</label>
                <select
                  v-model="form.status"
                  class="w-full h-11 px-md bg-surface-container-lowest border border-outline-variant rounded-xl focus:ring-2 focus:ring-primary focus:border-primary transition-all font-body-md text-body-md text-on-surface"
                >
                  <option :value="0">Activo</option>
                  <option :value="1">Inactivo</option>
                </select>
              </div>
            </div>
            <div class="flex flex-col-reverse sm:flex-row justify-end gap-md pt-md border-t border-outline-variant">
              <button
                type="button"
                class="h-11 px-lg rounded-xl border border-outline-variant text-on-surface-variant font-bold hover:bg-surface-container transition-all"
                @click="dialogOpen = false"
              >Cancelar</button>
              <button
                type="submit"
                :disabled="saving"
                class="h-11 px-lg rounded-xl bg-primary text-on-primary font-bold hover:shadow-lg active:scale-[0.98] transition-all disabled:opacity-50 flex items-center justify-center gap-xs"
              >
                <template v-if="saving">
                  <span class="animate-spin material-symbols-outlined text-[18px]">sync</span>
                  Guardando...
                </template>
                <template v-else>
                  {{ editing ? "Actualizar" : "Crear" }}
                </template>
              </button>
            </div>
          </form>
        </div>
      </div>
    </Teleport>

    <!-- Delete Confirm Dialog -->
    <Teleport to="body">
      <div v-if="deletingConfirm" class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="absolute inset-0 bg-black/30 backdrop-blur-sm" @click="deletingConfirm = false"></div>
        <div class="relative bg-surface-container-lowest rounded-xl shadow-2xl border border-outline-variant w-full max-w-sm mx-auto p-md md:p-xl">
          <div class="flex items-start gap-md mb-lg">
            <div class="w-12 h-12 rounded-full bg-error-container/30 flex items-center justify-center shrink-0">
              <span class="material-symbols-outlined text-error text-[28px]">warning</span>
            </div>
            <div>
              <h3 class="font-headline-sm text-headline-sm text-on-surface">Eliminar Unidad</h3>
              <p class="text-body-md text-on-surface-variant mt-1">¿Estás seguro de eliminar <strong>{{ deleting?.name }}</strong>?</p>
              <p class="text-body-md text-on-surface-variant">Esta acción no se puede deshacer.</p>
            </div>
          </div>
          <div class="flex flex-col-reverse sm:flex-row justify-end gap-md">
            <button
              class="h-11 px-lg rounded-xl border border-outline-variant text-on-surface-variant font-bold hover:bg-surface-container transition-all"
              @click="deletingConfirm = false"
            >Cancelar</button>
            <button
              class="h-11 px-lg rounded-xl bg-error text-on-error font-bold hover:shadow-lg active:scale-[0.98] transition-all flex items-center justify-center gap-xs"
              @click="doDelete"
            >Eliminar</button>
          </div>
        </div>
      </div>
    </Teleport>
  </div>
</template>
