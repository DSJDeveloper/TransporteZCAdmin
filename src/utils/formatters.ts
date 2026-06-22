export const DEFAULT_LOCALE = 'es-AR'
export const CURRENCY_LOCALE = 'en-US'
export const CURRENCY_CODE = 'USD'

function createCache<K extends string, V>(): { get(key: K, factory: () => V): V } {
  const cache = new Map<K, V>()
  return {
    get(key: K, factory: () => V): V {
      let instance = cache.get(key)
      if (!instance) {
        instance = factory()
        cache.set(key, instance)
      }
      return instance
    },
  }
}

const dateFormatters = createCache<string, Intl.DateTimeFormat>()
const timeFormatters = createCache<string, Intl.DateTimeFormat>()
const dateTimeFormatters = createCache<string, Intl.DateTimeFormat>()
const currencyFormatters = createCache<string, Intl.NumberFormat>()

function _toDate(value: string | number | Date | null | undefined): Date | null {
  if (value == null) return null
  if (value instanceof Date) return isNaN(value.getTime()) ? null : value
  let v = value
  if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v)) {
    v = v + 'T00:00:00'
  }
  const d = typeof v === 'string' ? new Date(v) : new Date(v)
  return isNaN(d.getTime()) ? null : d
}

export function toDate(str: string): Date | undefined {
  return str ? new Date(str + 'T00:00:00') : undefined
}

export function toStr(date: Date | undefined | null): string {
  if (!date) return ''
  const y = date.getFullYear()
  const m = String(date.getMonth() + 1).padStart(2, '0')
  const d = String(date.getDate()).padStart(2, '0')
  return `${y}-${m}-${d}`
}

export function formatDate(
  value: string | number | Date | null | undefined,
  locale = DEFAULT_LOCALE,
): string {
  const date = _toDate(value)
  if (!date) return ''

  const formatter = dateFormatters.get(locale, () =>
    new Intl.DateTimeFormat(locale, {
      day: '2-digit',
      month: '2-digit',
      year: 'numeric',
    }),
  )
  return formatter.format(date)
}

export function formatDateShort(
  value: string | number | Date | null | undefined,
  locale = DEFAULT_LOCALE,
): string {
  const date = _toDate(value)
  if (!date) return ''

  const formatter = dateFormatters.get(`short:${locale}`, () =>
    new Intl.DateTimeFormat(locale, {
      day: 'numeric',
      month: 'short',
      year: 'numeric',
    }),
  )
  return formatter.format(date)
}

export function formatTime(
  value: string | number | Date | null | undefined,
  options?: { hour12?: boolean; locale?: string },
): string {
  const date = _toDate(value)
  if (!date) return ''

  const { hour12 = false, locale = DEFAULT_LOCALE } = options ?? {}
  const key = `${locale}:hour12=${hour12}`

  const formatter = timeFormatters.get(key, () =>
    new Intl.DateTimeFormat(locale, {
      hour: '2-digit',
      minute: '2-digit',
      hour12,
    }),
  )
  return formatter.format(date)
}

export function formatDateTime(
  value: string | number | Date | null | undefined,
  options?: { hour12?: boolean; locale?: string; dateStyle?: 'full' | 'long' | 'medium' | 'short' },
): string {
  const date = _toDate(value)
  if (!date) return ''

  const { hour12 = false, locale = DEFAULT_LOCALE, dateStyle } = options ?? {}

  if (dateStyle) {
    const key = `dt:${locale}:hour12=${hour12}:${dateStyle}`
    const formatter = dateTimeFormatters.get(key, () =>
      new Intl.DateTimeFormat(locale, {
        dateStyle,
        timeStyle: 'short',
        hour12,
      }),
    )
    return formatter.format(date)
  }

  const key = `dt:${locale}:hour12=${hour12}`
  const formatter = dateTimeFormatters.get(key, () =>
    new Intl.DateTimeFormat(locale, {
      day: '2-digit',
      month: '2-digit',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      hour12,
    }),
  )
  return formatter.format(date)
}

export function formatCurrency(
  amount: number | null | undefined,
  locale = CURRENCY_LOCALE,
  currency = CURRENCY_CODE,
): string {
  if (amount == null) return ''

  const key = `${locale}:${currency}`
  const formatter = currencyFormatters.get(key, () =>
    new Intl.NumberFormat(locale, {
      style: 'currency',
      currency,
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    }),
  )
  return formatter.format(amount)
}

export function formatCount(
  n: number | null | undefined,
  locale = 'en-US',
): string {
  if (n == null) return ''
  return n.toLocaleString(locale)
}

export function formatCurrencyWithSign(
  amount: number | null | undefined,
  locale = CURRENCY_LOCALE,
  currency = CURRENCY_CODE,
): string {
  if (amount == null) return ''
  if (amount > 0) return '+' + formatCurrency(amount, locale, currency)
  if (amount < 0) return '-' + formatCurrency(Math.abs(amount), locale, currency)
  return formatCurrency(0, locale, currency)
}
