import { supabase } from "./supabaseClient"

export interface Stop {
  id: number
  name: string
  description: string
  status: number
}

export type StopForm = Omit<Stop, "id">

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export async function getStops(): Promise<Stop[]> {
  const { data: raw, error } = await supabase.rpc("manage_stop", {
    p_action: "list",
    p_id: null,
    p_name: null,
    p_description: null,
    p_status: null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Stop[]>
  if (!result.success) throw new Error(result.message ?? "Error al cargar las paradas")
  return result.data ?? []
}

export async function createStop(input: StopForm): Promise<Stop> {
  const { data: raw, error } = await supabase.rpc("manage_stop", {
    p_action: "create",
    p_id: null,
    p_name: input.name,
    p_description: input.description,
    p_status: input.status,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Stop>
  if (!result.success) throw new Error(result.message ?? "Error al crear la parada")
  return result.data as Stop
}

export async function updateStop(id: number, input: Partial<StopForm>): Promise<Stop> {
  const { data: raw, error } = await supabase.rpc("manage_stop", {
    p_action: "update",
    p_id: id,
    p_name: input.name ?? null,
    p_description: input.description ?? null,
    p_status: input.status ?? null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Stop>
  if (!result.success) throw new Error(result.message ?? "Error al actualizar la parada")
  return result.data as Stop
}

export async function deleteStop(id: number): Promise<void> {
  const { data: raw, error } = await supabase.rpc("manage_stop", {
    p_action: "delete",
    p_id: id,
    p_name: null,
    p_description: null,
    p_status: null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<never>
  if (!result.success) throw new Error(result.message ?? "Error al eliminar la parada")
}
