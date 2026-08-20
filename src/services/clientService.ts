import { supabase } from "./supabaseClient"

export interface Debtor {
  id: number
  name: string
  documentID: string
  balance: number
}

export interface Client {
  id: number
  name: string
  documentID: string
  email: string
  phone: string
  carrer: string
  creditLimit: string
  status: string
  balance: number
  uid: string
  idroute: number | null
  route_name: string | null
  auth_user_name: string | null
  photo_url: string | null
}

export interface PaginatedClientsParams {
  page: number
  perPage: number
  search?: string
  status?: string
  idroute?: number | null
  sortField?: string
  sortOrder?: string
}

export interface PaginatedClientsResult {
  data: Client[]
  total: number
}

export type ClientForm = {
  name: string
  documentID: string
  email: string
  phone: string
  carrer: string
  creditLimit: string
  status: string
  idroute: number | null
  photo_url: string | null
}

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export async function getDebtorsList(): Promise<Debtor[]> {
  const { data: raw, error } = await supabase.rpc("get_debtors_list")
  if (error) throw error
  const result = raw as unknown as { success: boolean; data?: Debtor[]; message?: string }
  if (!result.success) throw new Error(result.message ?? "Error al cargar deudores")
  return result.data ?? []
}

export async function getClients(): Promise<Client[]> {
  const { data: raw, error } = await supabase.rpc("get_clients")
  if (error) throw error
  const result = raw as unknown as { success: boolean; data?: Client[]; message?: string }
  if (!result.success) throw new Error(result.message ?? "Error al cargar los clientes")
  return result.data ?? []
}

export async function getClientsPaginated(params: PaginatedClientsParams): Promise<PaginatedClientsResult> {
  const { data: raw, error } = await supabase.rpc("get_clients_paginated", {
    p_page: params.page,
    p_per_page: params.perPage,
    p_search: params.search ?? null,
    p_status: params.status ?? null,
    p_sort_field: params.sortField ?? "id",
    p_sort_order: params.sortOrder ?? "ASC",
    p_idroute: params.idroute ?? null,
  })
  if (error) throw error
  const result = raw as unknown as { data?: Client[]; total?: number }
  return {
    data: result.data ?? [],
    total: result.total ?? 0,
  }
}

export async function createClient(client: ClientForm): Promise<Client> {
  const { data: raw, error } = await supabase.rpc("manage_client", {
    p_action: "create",
    p_id: null,
    p_name: client.name,
    p_document_id: client.documentID,
    p_email: client.email,
    p_phone: client.phone,
    p_carrer: client.carrer,
    p_credit_limit: client.creditLimit,
    p_status: client.status,
    p_idroute: client.idroute ?? null,
    p_photo_url: client.photo_url ?? null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Client>
  if (!result.success) throw new Error(result.message ?? "Error al crear el cliente")
  return result.data as Client
}

export async function updateClient(id: number, client: Partial<ClientForm>): Promise<Client> {
  const { data: raw, error } = await supabase.rpc("manage_client", {
    p_action: "update",
    p_id: id,
    p_name: client.name ?? null,
    p_document_id: client.documentID ?? null,
    p_email: client.email ?? null,
    p_phone: client.phone ?? null,
    p_carrer: client.carrer ?? null,
    p_credit_limit: client.creditLimit ?? null,
    p_status: client.status ?? null,
    p_idroute: client.idroute ?? null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Client>
  if (!result.success) throw new Error(result.message ?? "Error al actualizar el cliente")
  return result.data as Client
}

export async function deleteClient(id: number): Promise<{ message: string; deactivated: boolean }> {
  const { data: raw, error } = await supabase.rpc("manage_client", {
    p_action: "delete",
    p_id: id,
    p_name: null,
    p_document_id: null,
    p_email: null,
    p_phone: null,
    p_carrer: null,
    p_credit_limit: null,
    p_status: null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<never> & { deactivated?: boolean }
  if (!result.success) throw new Error(result.message ?? "Error al eliminar el cliente")
  return { message: result.message ?? "", deactivated: result.deactivated ?? false }
}
