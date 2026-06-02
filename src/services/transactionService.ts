import { supabase } from "./supabaseClient"

export interface Transaction {
  id: number
  uid: string
  idclient: number
  createBy: number
  amount: number
  status: number
  created_at: string
  idunit: number
  shedule: string | null
  newBalanceClient: number | null
  clients: { name: string } | null
  units: { name: string } | null
}

export interface TransactionFilters {
  dateFrom: string | null
  dateTo: string | null
  idunit: number | null
  status: number | null
}

const ALLOWED_COLUMNS = new Set([
  "id", "uid", "idclient", "createBy", "amount", "status",
  "created_at", "idunit", "shedule", "newBalanceClient",
])

let clientNameCache: Record<number, string> | null = null
let unitNameCache: Record<number, string> | null = null

async function getClientNames(): Promise<Record<number, string>> {
  if (clientNameCache) return clientNameCache
  const { data } = await supabase.from("clients").select("id, name")
  const map: Record<number, string> = {}
  for (const c of data ?? []) {
    map[c.id] = c.name
  }
  clientNameCache = map
  return map
}

async function getUnitNames(): Promise<Record<number, string>> {
  if (unitNameCache) return unitNameCache
  const { data } = await supabase.from("units").select("id, name")
  const map: Record<number, string> = {}
  for (const u of data ?? []) {
    map[u.id] = u.name
  }
  unitNameCache = map
  return map
}

export async function exportTransactions(filters: TransactionFilters, sortField: string, sortAsc: boolean): Promise<Transaction[]> {
  let query = supabase
    .from('transactions')
    .select('id, uid, idclient, createBy, amount, status, created_at, idunit, shedule, newBalanceClient')

  if (filters.dateFrom && /^\d{4}-\d{2}-\d{2}$/.test(filters.dateFrom)) {
    query = query.gte('created_at', filters.dateFrom)
  }
  if (filters.dateTo && /^\d{4}-\d{2}-\d{2}$/.test(filters.dateTo)) {
    query = query.lte('created_at', `${filters.dateTo}T23:59:59`)
  }
  if (filters.idunit != null && Number.isInteger(filters.idunit) && filters.idunit >= 0) {
    query = query.eq('idunit', filters.idunit)
  }
  if (filters.status != null && [0, 1, 2].includes(filters.status)) {
    query = query.eq('status', filters.status)
  }

  const safeField = ALLOWED_COLUMNS.has(sortField) ? sortField : 'created_at'
  query = query.order(safeField, { ascending: sortAsc })

  const { data, error } = await query
  if (error) throw error

  const raw = (data ?? []) as unknown as Transaction[]
  const [clientNames, unitNames] = await Promise.all([getClientNames(), getUnitNames()])

  return raw.map((row) => ({
    ...row,
    clients: clientNames[row.idclient] ? { name: clientNames[row.idclient] ?? '' } : null,
    units: unitNames[row.idunit] ? { name: unitNames[row.idunit] ?? '' } : null,
  })) as Transaction[]
}

export function clearNameCaches() {
  clientNameCache = null
  unitNameCache = null
}

export async function getTransactions(params: {
  page: number
  perPage: number
  filters: TransactionFilters
  sortField: string
  sortAsc: boolean
}): Promise<{ data: Transaction[]; count: number }> {
  const { page, perPage, filters, sortField, sortAsc } = params

  let query = supabase
    .from("transactions")
    .select(
      "id, uid, idclient, createBy, amount, status, created_at, idunit, shedule, newBalanceClient",
      { count: "exact" },
    )

  if (filters.dateFrom && /^\d{4}-\d{2}-\d{2}$/.test(filters.dateFrom)) {
    query = query.gte("created_at", filters.dateFrom)
  }
  if (filters.dateTo && /^\d{4}-\d{2}-\d{2}$/.test(filters.dateTo)) {
    query = query.lte("created_at", `${filters.dateTo}T23:59:59`)
  }
  if (filters.idunit != null && Number.isInteger(filters.idunit) && filters.idunit >= 0) {
    query = query.eq("idunit", filters.idunit)
  }
  if (filters.status != null && [0, 1, 2].includes(filters.status)) {
    query = query.eq("status", filters.status)
  }

  const safeField = ALLOWED_COLUMNS.has(sortField) ? sortField : "created_at"
  query = query.order(safeField, { ascending: sortAsc })

  const from = (page - 1) * perPage
  query = query.range(from, from + perPage - 1)

  const { data, error, count } = await query
  if (error) throw error

  const raw = (data ?? []) as unknown as Transaction[]

  const [clientNames, unitNames] = await Promise.all([getClientNames(), getUnitNames()])

  return {
    data: raw.map((row) => {
      const clientName = clientNames[row.idclient]
      const unitName = unitNames[row.idunit]
      return {
        ...row,
        clients: clientName ? { name: clientName } : null,
        units: unitName ? { name: unitName } : null,
      }
    }),
    count: count ?? 0,
  }
}
