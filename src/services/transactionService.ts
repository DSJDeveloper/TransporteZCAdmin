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

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export async function exportTransactions(filters: TransactionFilters, sortField: string, sortAsc: boolean): Promise<Transaction[]> {
  const { data: raw, error } = await supabase.rpc("get_transactions_export", {
    p_date_from: filters.dateFrom ?? null,
    p_date_to: filters.dateTo ?? null,
    p_idunit: filters.idunit ?? null,
    p_status: filters.status ?? null,
    p_sort_field: sortField,
    p_sort_order: sortAsc ? "ASC" : "DESC",
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Transaction[]>
  return result.data ?? []
}

export interface TripRecord {
  date: string
  client_name: string
  unit_name: string
  route_name: string
}

export async function getTripsByDateRange(dateFrom: string, dateTo: string): Promise<TripRecord[]> {
  const { data: raw, error } = await supabase.rpc("get_trips_by_date_range", {
    p_date_from: dateFrom,
    p_date_to: dateTo,
  })
  if (error) throw error
  return (raw ?? []) as TripRecord[]
}

export async function getTransactions(params: {
  page: number
  perPage: number
  filters: TransactionFilters
  sortField: string
  sortAsc: boolean
}): Promise<{ data: Transaction[]; count: number }> {
  const { page, perPage, filters, sortField, sortAsc } = params

  const { data: raw, error } = await supabase.rpc("get_transactions_paginated", {
    p_page: page,
    p_per_page: perPage,
    p_date_from: filters.dateFrom ?? null,
    p_date_to: filters.dateTo ?? null,
    p_idunit: filters.idunit ?? null,
    p_status: filters.status ?? null,
    p_sort_field: sortField,
    p_sort_order: sortAsc ? "ASC" : "DESC",
  })
  if (error) throw error
  const result = raw as unknown as { data: Transaction[]; total: number }
  return { data: result.data ?? [], count: result.total ?? 0 }
}
