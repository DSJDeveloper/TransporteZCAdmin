import { ref } from "vue"

export function useDialog<T = void>() {
  const visible = ref(false)
  const data = ref<T | null>(null)

  function open(payload?: T) {
    data.value = (payload ?? null) as T | null
    visible.value = true
  }

  function close() {
    visible.value = false
    data.value = null
  }

  return { visible, data, open, close }
}

export function useConfirmDialog() {
  const visible = ref(false)
  const title = ref("")
  const message = ref("")
  const confirmLabel = ref("Confirmar")
  const loading = ref(false)
  let onResolve: (() => void) | null = null

  function ask(opts: {
    title?: string
    message: string
    confirmLabel?: string
  }): Promise<boolean> {
    title.value = opts.title ?? "Confirmar"
    message.value = opts.message
    confirmLabel.value = opts.confirmLabel ?? "Confirmar"
    visible.value = true
    loading.value = false
    return new Promise((resolve) => {
      onResolve = () => {
        resolve(true)
      }
    })
  }

  function confirm() {
    onResolve?.()
    onResolve = null
    visible.value = false
  }

  function cancel() {
    onResolve = null
    visible.value = false
  }

  return { visible, title, message, confirmLabel, loading, ask, confirm, cancel }
}
