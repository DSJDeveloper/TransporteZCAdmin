<script setup lang="ts">
defineProps<{
  label: string
  value: string
  icon: string
  trend?: string
  trendUp?: boolean
  subtitle?: string
  accent?: boolean
  bar?: number
  color?: 'error' | 'primary' | 'tertiary' | 'warning'
  loading?: boolean
}>()
</script>

<template>
  <div
    class="p-lg rounded-xl flex flex-col justify-between h-48 transition-all"
    :class="accent
      ? 'bg-primary-container text-on-primary-container shadow-lg'
      : 'bg-surface-container-lowest border border-outline-variant shadow-sm hover:border-primary'"
  >
    <!-- loading skeleton -->
    <template v-if="loading">
      <div class="space-y-md">
        <div class="flex justify-between items-start">
          <div class="p-sm rounded-lg bg-surface-container h-10 w-10 animate-pulse" />
          <div class="h-4 w-16 rounded bg-surface-container animate-pulse" />
        </div>
        <div class="space-y-xs">
          <div class="h-3 w-24 rounded bg-surface-container animate-pulse" />
          <div class="h-8 w-32 rounded bg-surface-container animate-pulse" />
        </div>
      </div>
    </template>

    <template v-else>
      <div class="flex justify-between items-start">
        <div
          class="p-sm rounded-lg"
          :class="accent ? 'bg-white/20' : color === 'error'
            ? 'bg-error-container/20'
            : color === 'tertiary'
              ? 'bg-tertiary-container/10'
              : color === 'warning'
                ? 'bg-amber-100'
                : 'bg-primary-container/10'"
        >
          <span
            class="material-symbols-outlined"
            :class="accent ? 'text-white' : color === 'error'
              ? 'text-error'
              : color === 'tertiary'
                ? 'text-tertiary'
                : color === 'warning'
                  ? 'text-amber-600'
                  : 'text-primary'"
          >{{ icon }}</span>
        </div>
        <span
          v-if="trend"
          class="font-bold flex items-center text-label-md px-xs py-1 rounded whitespace-nowrap"
          :class="accent ? 'bg-white/20 text-white' : color === 'error'
            ? 'bg-error-container/30 text-error'
            : 'bg-tertiary-container/20 text-tertiary'"
        >
          <span v-if="trendUp !== undefined" class="material-symbols-outlined !text-sm mr-[2px]">
            {{ trendUp ? 'trending_up' : 'trending_down' }}
          </span>
          {{ trend }}
        </span>
      </div>

      <div>
        <h3
          class="font-label-md uppercase tracking-wider"
          :class="accent ? 'text-white/80' : 'text-on-surface-variant'"
        >{{ label }}</h3>
        <p
          class="font-headline-lg text-headline-lg"
          :class="accent ? 'text-white' : color === 'error'
            ? 'text-error'
            : 'text-on-surface'"
        >{{ value }}</p>
        <p
          v-if="subtitle"
          class="text-label-md"
          :class="accent ? 'text-white/70' : 'text-outline'"
        >{{ subtitle }}</p>
        <div
          v-if="bar !== undefined"
          class="w-full bg-surface-container h-1.5 rounded-full mt-2"
        >
          <div
            class="bg-tertiary h-full rounded-full"
            :style="{ width: Math.min(bar, 100) + '%' }"
          />
        </div>
      </div>
    </template>
  </div>
</template>
