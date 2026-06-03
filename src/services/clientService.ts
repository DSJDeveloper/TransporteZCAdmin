import { supabase } from "./supabaseClient"

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
}

export type ClientForm = {
  name: string
  documentID: string
  email: string
  phone: string
  carrer: string
  creditLimit: string
  status: string
}

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export async function getClients(): Promise<Client[]> {
  const { data: raw, error } = await supabase.rpc("get_clients")
  if (error) throw error
  const result = raw as unknown as { success: boolean; data?: Client[]; message?: string }
  if (!result.success) throw new Error(result.message ?? "Error al cargar los clientes")
  return result.data ?? []
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
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Client>
  if (!result.success) throw new Error(result.message ?? "Error al actualizar el cliente")
  return result.data as Client
}

export async function deleteClient(id: number): Promise<void> {
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
  const result = raw as unknown as RpcResult<never>
  if (!result.success) throw new Error(result.message ?? "Error al eliminar el cliente")
}
