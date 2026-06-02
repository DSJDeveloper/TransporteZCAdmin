import { supabase } from "./supabaseClient"

export interface Recharge {
  id: number
  idclient: number
  method: string
  ref: string | null
  picture: string | null
  amount: number
  tasa: number | null
  date: string
  status: number
  createBy: string | null
  createAt: string | null
  updateAprobate: string | null
  clients: { name: string } | null
}

export interface RechargeStats {
  pending: number
  rejected: number
  approved: number
  total_amount: number
}

interface RpcResult {
  success: boolean
  message?: string
}

interface PaginatedResult {
  data: Recharge[]
  total: number
}

export interface RechargeFilters {
  status?: number | null
  dateFrom?: string | null
  dateTo?: string | null
  method?: string | null
}

export async function getRecharges(
  page: number,
  perPage: number,
  filters?: RechargeFilters,
  sortField?: string,
  sortAsc?: boolean,
): Promise<{ data: Recharge[]; count: number }> {
  const { data: raw, error } = await supabase.rpc("get_recharges_paginated", {
    p_page: page,
    p_per_page: perPage,
    p_status: filters?.status ?? null,
    p_date_from: filters?.dateFrom ?? null,
    p_date_to: filters?.dateTo ?? null,
    p_method: filters?.method ?? null,
    p_sort_field: sortField ?? "id",
    p_sort_order: sortAsc !== undefined ? (sortAsc ? "ASC" : "DESC") : "DESC",
  })
  if (error) throw error
  const result = raw as unknown as PaginatedResult
  return { data: result.data ?? [], count: result.total ?? 0 }
}

export async function getRechargeStats(): Promise<RechargeStats> {
  const { data, error } = await supabase.rpc("get_recharge_stats")
  if (error) throw error
  return data as unknown as RechargeStats
}

export async function processRechargeStatus(
  rechargeId: number,
  action: "approve" | "reject",
  approvedBy: string,
): Promise<void> {
  const { data: raw, error } = await supabase.rpc("process_recharge_status", {
    p_recharge_id: rechargeId,
    p_action: action,
    p_approved_by: approvedBy,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult
  if (!result.success) throw new Error(result.message ?? "Error al procesar la recarga")
}
