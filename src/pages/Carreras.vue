<script setup lang="ts">
import { ref, computed, reactive, onMounted, watch } from "vue"
import { useCareerStore } from "../stores/careerStore"
import type { Career, CareerForm } from "../services/careerService"

const store = useCareerStore()

const search = ref("")
const page = ref(1)
const perPage = ref(10)
const sortField = ref("id")
const sortAsc = ref(true)

const dialogOpen = ref(false)
const editing = ref<Career | null>(null)
const saving = ref(false)
const form = ref<CareerForm>({ code: "", description: "", status: 0 })
const errors = reactive<Record<string, string>>({})

const refreshing = ref(false)
async function refreshData() {
  refreshing.value = true
  await store.fetchAll()
  refreshing.value = false
}

const deleting = ref<Career | null>(null)
const deletingConfirm = ref(false)

const filtered = computed(() => {
  const q = search.value.toLowerCase().trim()
  if (!q) return store.list
  return store.list.filter(
    (c) =>
      c.code.toLowerCase().includes(q) ||
      c.description.toLowerCase().includes(q),
  )
})

const totalPages = computed(() => Math.max(1, Math.ceil(filtered.value.length / perPage.value)))

function compare(a: Career, b: Career, field: string): number {
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
  { key: "code", label: "CÓDIGO" },
  { key: "description", label: "DESCRIPCIÓN" },
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
  if (!form.value.code.trim()) e.code = "El código es obligatorio"
  if (!form.value.description.trim()) e.description = "La descripción es obligatoria"
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
  form.value = { code: "", description: "", status: 0 }
  clearErrors()
  dialogOpen.value = true
}

function openEdit(c: Career) {
  editing.value = c
  form.value = { code: c.code, description: c.description, status: c.status }
  clearErrors()
  dialogOpen.value = true
}

async function save() {
  clearErrors()
  if (!validate()) return
  saving.value = true
  try {
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

function confirmDelete(c: Career) {
  deleting.value = c
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

onMounted(() => store.fetchAll())
</script>

<template>
  <div class="p-margin-mobile md:p-margin-desktop min-h-screen">
    <div class="mb-lg">
      <div class="flex items-center gap-xs text-label-md text-outline mb-xs">
        <span>Configuraciones</span>
        <span class="material-symbols-outlined text-[14px]">chevron_right</span>
        <span class="text-primary font-bold">Carreras</span>
      </div>
      <h2 class="text-headline-lg text-on-surface font-bold">Gestión de Carreras</h2>
      <p class="text-body-lg text-on-surface-variant">
        Administre las carreras disponibles en el sistema
      </p>
    </div>

    <section class="bg-surface-container-lowest rounded-xl border border-outline-variant shadow-sm overflow-hidden">
      <div class="p-md md:p-lg border-b border-outline-variant flex flex-col md:flex-row md:items-center md:justify-between gap-md bg-surface-container-low/30">
        <h4 class="text-headline-sm font-semibold text-on-surface">Lista de Carreras</h4>
        <button
          class="bg-primary hover:bg-surface-tint text-on-primary px-lg py-sm rounded-xl text-headline-sm font-bold flex items-center justify-center gap-sm transition-all shadow-md active:scale-95 w-full sm:w-auto"
          @click="openCreate"
        >
          <span class="material-symbols-outlined">add_circle</span>
          <span>Nueva Carrera</span>
        </button>
      </div>

      <div class="p-md md:p-lg border-b border-outline-variant flex flex-col md:flex-row md:items-center md:justify-between gap-md">
        <div class="flex items-center gap-md w-full md:w-auto">
          <div class="flex items-center gap-xs text-body-md text-on-surface-variant whitespace-nowrap">
            <span class="hidden md:inline">Mostrar</span>
            <select
              v-model.number="perPage"
              class="bg-surface-container-lowest border border-outline-variant rounded-lg text-body-md py-1 pl-2 pr-1 focus:ring-primary focus:border-primary outline-none"
            >
              <option :value="5">5</option>
              <option :value="10">10</option>
              <option :value="25">25</option>
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
        </div>
        <div class="relative w-full md:w-56">
          <span class="material-symbols-outlined absolute left-3 top-1/2 -translate-y-1/2 text-outline text-[18px]">search</span>
          <input
            v-model="search"
            class="w-full pl-9 pr-3 py-1.5 bg-surface-container-low border border-outline-variant rounded-lg text-body-md focus:border-primary outline-none transition-all"
            placeholder="Buscar carreras..."
            type="text"
          />
        </div>
      </div>

      <div v-if="store.loading" class="p-xl text-center text-on-surface-variant">
        <span class="animate-spin material-symbols-outlined inline-block">sync</span>
        <p class="mt-2">Cargando carreras...</p>
      </div>

      <div v-else-if="!filtered.length" class="p-xl text-center text-on-surface-variant">
        <span class="material-symbols-outlined text-[48px] text-outline">school</span>
        <p class="mt-2">No se encontraron carreras</p>
      </div>

      <template v-else>
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
              <tr v-for="c in paginated" :key="c.id" class="hover:bg-primary-container/5 transition-colors group">
                <td class="px-lg py-md text-outline font-bold">{{ String(c.id).padStart(2, "0") }}</td>
                <td class="px-lg py-md">
                  <code class="bg-surface-container-high px-xs rounded text-primary font-bold">{{ c.code }}</code>
                </td>
                <td class="px-lg py-md text-on-surface font-bold">{{ c.description }}</td>
                <td class="px-lg py-md text-center">
                  <span
                    v-if="c.status === 0"
                    class="bg-tertiary-fixed text-on-tertiary-fixed px-sm py-1 rounded-full text-[12px] font-bold"
                  >Activo</span>
                  <span
                    v-else
                    class="bg-error-container text-on-error-container px-sm py-1 rounded-full text-[12px] font-bold"
                  >Inactivo</span>
                </td>
                <td class="px-lg py-md text-right">
                  <div class="flex justify-end gap-xs opacity-40 group-hover:opacity-100 transition-all duration-200">
                    <button class="p-xs hover:bg-primary/10 rounded-lg text-primary transition-colors" title="Editar" @click="openEdit(c)">
                      <span class="material-symbols-outlined">edit</span>
                    </button>
                    <button class="p-xs hover:bg-error/10 rounded-lg text-error transition-colors" title="Eliminar" @click="confirmDelete(c)">
                      <span class="material-symbols-outlined">delete</span>
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="md:hidden divide-y divide-outline-variant">
          <div v-for="c in paginated" :key="c.id" class="p-md space-y-sm">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-sm">
                <div class="w-8 h-8 rounded bg-primary/10 flex items-center justify-center text-primary">
                  <span class="material-symbols-outlined text-[18px]">school</span>
                </div>
                <div>
                  <span class="font-bold text-on-surface">{{ c.description }}</span>
                  <code class="ml-2 bg-surface-container-high px-1.5 rounded text-primary font-bold text-[12px]">{{ c.code }}</code>
                </div>
              </div>
              <span
                v-if="c.status === 0"
                class="bg-tertiary-fixed text-on-tertiary-fixed px-2 py-0.5 rounded-full text-[11px] font-bold"
              >Activo</span>
              <span
                v-else
                class="bg-error-container text-on-error-container px-2 py-0.5 rounded-full text-[11px] font-bold"
              >Inactivo</span>
            </div>
            <div class="flex justify-end gap-xs pt-xs">
              <button
                class="flex-1 flex items-center justify-center gap-1 py-2 rounded-lg border border-outline-variant text-primary font-bold text-[13px] hover:bg-primary-container/10 transition-colors"
                @click="openEdit(c)"
              >
                <span class="material-symbols-outlined text-[18px]">edit</span>
                Editar
              </button>
              <button
                class="flex-1 flex items-center justify-center gap-1 py-2 rounded-lg border border-outline-variant text-error font-bold text-[13px] hover:bg-error-container/10 transition-colors"
                @click="confirmDelete(c)"
              >
                <span class="material-symbols-outlined text-[18px]">delete</span>
                Eliminar
              </button>
            </div>
          </div>
        </div>
      </template>

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
  </div>

  <Teleport to="body">
    <div v-if="dialogOpen" class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div class="absolute inset-0 bg-black/30 backdrop-blur-sm" @click="dialogOpen = false"></div>
      <div class="relative bg-surface-container-lowest rounded-xl shadow-2xl border border-outline-variant w-full max-w-lg mx-auto p-md md:p-xl max-h-[90vh] overflow-y-auto">
        <div class="flex items-center justify-between mb-lg">
          <h3 class="font-headline-sm text-headline-sm text-on-surface">
            {{ editing ? "Editar Carrera" : "Nueva Carrera" }}
          </h3>
          <button class="text-outline hover:text-on-surface transition-colors" @click="dialogOpen = false">
            <span class="material-symbols-outlined">close</span>
          </button>
        </div>
        <form @submit.prevent="save" class="space-y-lg">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-lg">
            <div class="space-y-base">
              <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Código</label>
              <input
                v-model="form.code"
                :class="[
                  'w-full h-11 px-md bg-surface-container-lowest border rounded-xl transition-all font-body-md text-body-md outline-none',
                  errors.code
                    ? 'border-error focus:ring-2 focus:ring-error focus:border-error'
                    : 'border-outline-variant focus:ring-2 focus:ring-primary focus:border-primary'
                ]"
                placeholder="Ej. INF-2024"
                @input="errors.code && delete errors.code"
              />
              <p v-if="errors.code" class="text-error text-[12px] font-bold">{{ errors.code }}</p>
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
            <div class="space-y-base md:col-span-2">
              <label class="font-label-md text-label-md text-on-surface-variant uppercase tracking-wider">Descripción</label>
              <input
                v-model="form.description"
                :class="[
                  'w-full h-11 px-md bg-surface-container-lowest border rounded-xl transition-all font-body-md text-body-md outline-none',
                  errors.description
                    ? 'border-error focus:ring-2 focus:ring-error focus:border-error'
                    : 'border-outline-variant focus:ring-2 focus:ring-primary focus:border-primary'
                ]"
                placeholder="Ej. Ingeniería Informática"
                @input="errors.description && delete errors.description"
              />
              <p v-if="errors.description" class="text-error text-[12px] font-bold">{{ errors.description }}</p>
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

  <Teleport to="body">
    <div v-if="deletingConfirm" class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div class="absolute inset-0 bg-black/30 backdrop-blur-sm" @click="deletingConfirm = false"></div>
      <div class="relative bg-surface-container-lowest rounded-xl shadow-2xl border border-outline-variant w-full max-w-sm mx-auto p-md md:p-xl">
        <div class="flex items-start gap-md mb-lg">
          <div class="w-12 h-12 rounded-full bg-error-container/30 flex items-center justify-center shrink-0">
            <span class="material-symbols-outlined text-error text-[28px]">warning</span>
          </div>
          <div>
            <h3 class="font-headline-sm text-headline-sm text-on-surface">Eliminar Carrera</h3>
            <p class="text-body-md text-on-surface-variant mt-1">¿Estás seguro de eliminar <strong>{{ deleting?.description }}</strong>?</p>
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
</template>
